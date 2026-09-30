"""Apply the existing PostgreSQL authorization migrations safely.

This runner deliberately does not alter migration files. Use --inspect first;
the default mode creates only the history table and applies pending files.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

from sqlalchemy import create_engine, inspect, text


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations"
HISTORY_TABLE = "insightflow_schema_migrations"
EXPECTED_TABLES = {
    "principals", "identity_bindings", "organizations", "workspaces",
    "organization_members", "roles", "permissions", "role_permissions",
    "member_roles", "invitations", "approved_employees", "delegations",
    "authorization_resources", "audit_events", "resource_grants",
    "dataset_authorization", "working_copy_authorization",
    "locations", "sections", "organizational_assignments",
    "datasets", "dataset_versions", "dataset_columns", "dataset_rows",
}


def migration_files() -> list[Path]:
    return sorted(MIGRATIONS.glob("[0-9][0-9][0-9][0-9]_*.sql"))


def require_database_url() -> str:
    value = os.environ.get("DATABASE_URL", "").strip()
    if not value:
        raise RuntimeError("DATABASE_URL is required.")
    if not value.lower().startswith(("postgresql://", "postgresql+psycopg2://", "postgres://")):
        raise RuntimeError("Refusing non-PostgreSQL DATABASE_URL.")
    return value


def connect():
    # The URL is passed directly to SQLAlchemy and is never printed.
    database_url = require_database_url()
    # SQLAlchemy defaults plain postgresql:// URLs to psycopg2. Production
    # InsightFlow ships psycopg v3, so normalize the URL without exposing it.
    if database_url.startswith("postgresql://"):
        database_url = "postgresql+psycopg://" + database_url[len("postgresql://"):]
    elif database_url.startswith("postgres://"):
        database_url = "postgresql+psycopg://" + database_url[len("postgres://"):]
    return create_engine(database_url, future=True, pool_pre_ping=True)


def inspect_database(engine) -> tuple[set[str], set[str]]:
    inspector = inspect(engine)
    tables = set(inspector.get_table_names())
    applied: set[str] = set()
    if HISTORY_TABLE in tables:
        with engine.connect() as conn:
            applied = {
                row[0]
                for row in conn.execute(text(f"SELECT version FROM {HISTORY_TABLE}"))
            }
    return tables, applied


def ensure_history(engine) -> None:
    with engine.begin() as conn:
        conn.execute(text(f"""
            CREATE TABLE IF NOT EXISTS {HISTORY_TABLE} (
                version TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """))


def apply_pending(engine) -> tuple[list[str], list[str]]:
    ensure_history(engine)
    newly_applied: list[str] = []
    already_applied: list[str] = []
    with engine.connect() as lock_conn:
        lock_conn.execute(text(
            "SELECT pg_advisory_lock(hashtext('insightflow-authz-migrations'))"
        ))
        try:
            _, applied = inspect_database(engine)
            for path in migration_files():
                version = path.stem
                if version in applied:
                    already_applied.append(version)
                    continue
                sql = path.read_text(encoding="utf-8")
                try:
                    with engine.begin() as conn:
                        conn.exec_driver_sql(sql)
                        conn.execute(
                            text(f"INSERT INTO {HISTORY_TABLE}(version) VALUES (:version)"),
                            {"version": version},
                        )
                except Exception:
                    raise
                newly_applied.append(version)
        finally:
            lock_conn.execute(text(
                "SELECT pg_advisory_unlock(hashtext('insightflow-authz-migrations'))"
            ))
    return newly_applied, already_applied


def verify_organizational_structure(engine) -> None:
    inspector = inspect(engine)
    required_columns = {
        "locations": {"organization_id", "location_id"},
        "sections": {"organization_id", "location_id"},
        "organizational_assignments": {
            "organization_id", "principal_id", "location_id", "section_id",
            "role_id", "reports_to_assignment_id", "status",
        },
    }
    for table, expected in required_columns.items():
        if not inspector.has_table(table):
            raise RuntimeError(f"Required organizational table is missing: {table}")
        actual = {column["name"] for column in inspector.get_columns(table)}
        missing = sorted(expected - actual)
        if missing:
            raise RuntimeError(
                f"Required columns missing from {table}: {','.join(missing)}"
            )

    with engine.connect() as conn:
        rows = conn.execute(text(
            """
            SELECT indexname, indexdef
            FROM pg_indexes
            WHERE schemaname = current_schema()
              AND tablename = 'organizational_assignments'
              AND indexname IN (
                'uq_active_manager_per_location',
                'uq_active_assignment_context'
              )
            ORDER BY indexname
            """
        )).all()
    indexes = {row[0]: row[1] for row in rows}
    if "uq_active_manager_per_location" not in indexes:
        raise RuntimeError("Missing uq_active_manager_per_location.")
    manager_index = indexes["uq_active_manager_per_location"].lower()
    if "role_id = 'manager'" not in manager_index or "status = 'active'" not in manager_index:
        raise RuntimeError("uq_active_manager_per_location is not the required active-manager constraint.")
    if "uq_active_assignment_context" not in indexes:
        raise RuntimeError("Missing uq_active_assignment_context.")




def verify_managed_dataset_security(engine) -> None:
    inspector = inspect(engine)
    required = {"datasets", "dataset_versions", "dataset_columns", "dataset_rows"}
    missing = sorted(required - set(inspector.get_table_names()))
    if missing:
        raise RuntimeError("Managed dataset tables are missing: " + ",".join(missing))
    with engine.connect() as conn:
        dataset_columns = {column["name"] for column in inspect(engine).get_columns("dataset_columns")}
        if "missing_count" not in dataset_columns:
            raise RuntimeError("Managed dataset profiling column missing: dataset_columns.missing_count.")
        rows = conn.execute(text("""
            SELECT c.relname, c.relrowsecurity
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema()
              AND c.relname = ANY(:tables)
        """), {"tables": sorted(required)}).all()
        rls = {row[0]: bool(row[1]) for row in rows}
        if any(not rls.get(table, False) for table in required):
            raise RuntimeError("Managed dataset RLS is not enabled on every analytical table.")
        bucket_exists = conn.execute(text("""
            SELECT 1 FROM storage.buckets
            WHERE id = 'managed-datasets' AND public = false
        """)).scalar_one_or_none()
        if bucket_exists is None:
            raise RuntimeError("Private managed-datasets Supabase Storage bucket is missing.")

def run_migrations() -> None:
    """Apply and verify pending production PostgreSQL migrations.

    Safe to call during application startup: migrations are versioned,
    transactional per file, and serialized with a PostgreSQL advisory lock.
    """
    engine = connect()
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    apply_pending(engine)
    final_tables, _ = inspect_database(engine)
    missing = sorted(EXPECTED_TABLES - final_tables)
    if missing:
        raise RuntimeError("Required authorization tables are missing: " + ",".join(missing))
    verify_organizational_structure(engine)
    verify_managed_dataset_security(engine)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect", action="store_true", help="read schema only")
    args = parser.parse_args()
    engine = connect()
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    tables, applied = inspect_database(engine)
    print("POSTGRESQL_CONNECTION=PASS")
    print("HISTORY_TABLE=" + ("EXISTS" if HISTORY_TABLE in tables else "MISSING"))
    print("AUTHORIZATION_TABLES_PRESENT=" + str(len(tables & EXPECTED_TABLES)))
    print("AUTHORIZATION_TABLES_EXPECTED=" + str(len(EXPECTED_TABLES)))
    if args.inspect:
        return 0
    applied_now, already = apply_pending(engine)
    print("APPLIED=" + ",".join(applied_now))
    print("ALREADY_APPLIED=" + ",".join(already))
    final_tables, _ = inspect_database(engine)
    missing = sorted(EXPECTED_TABLES - final_tables)
    print("IDENTITY_BINDINGS=" + ("EXISTS" if "identity_bindings" in final_tables else "MISSING"))
    if missing:
        print("REQUIRED_TABLES=FAIL")
    else:
        verify_organizational_structure(engine)
        verify_managed_dataset_security(engine)
        print("ORGANIZATIONAL_STRUCTURE=PASS")
        print("REQUIRED_TABLES=PASS")
    if missing:
        print("MISSING_TABLE_COUNT=" + str(len(missing)))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
