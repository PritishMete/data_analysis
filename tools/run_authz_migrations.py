"""Apply the existing PostgreSQL authorization migrations safely.

This runner deliberately does not alter migration files. Use --inspect first;
the default mode creates only the history table and applies pending files.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from sqlalchemy import create_engine, inspect, text


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
MIGRATIONS = ROOT / "migrations"
HISTORY_TABLE = "insightflow_schema_migrations"
EXPECTED_TABLES = {
    "principals", "identity_bindings", "organizations", "workspaces",
    "organization_members", "organization_member_profiles", "roles", "permissions", "role_permissions",
    "member_roles", "invitations", "approved_employees", "delegations",
    "authorization_resources", "audit_events", "resource_grants",
    "dataset_authorization", "working_copy_authorization",
    "locations", "sections", "organizational_assignments",
    "datasets", "dataset_versions", "dataset_columns", "dataset_rows", "dataset_change_proposals",
    "manager_dataset_upload_grants",
    "organization_employee_id_counters",
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
    # A dead/unreachable Supabase endpoint must fail promptly rather than
    # blocking FastAPI startup until the hosting platform kills the process.
    return create_engine(
        database_url,
        future=True,
        pool_pre_ping=True,
        connect_args={"connect_timeout": 10},
    )


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


def migrate_profile_pii(engine) -> None:
    """Encrypt legacy phone/ID values, then remove the plaintext columns.

    The operation is transactional and safe to repeat after a failed startup.
    A production key is required only when legacy plaintext values exist.
    """
    import re

    import pycountry

    from firebase_authz.profile_crypto import protect_profile_value
    from firebase_authz.profile_validation import normalize_id_proof_type

    inspector = inspect(engine)
    if not inspector.has_table("organization_member_profiles"):
        return
    columns = {column["name"] for column in inspector.get_columns("organization_member_profiles")}
    legacy = {"phone_e164", "id_proof_number"} & columns
    if not legacy:
        return

    with engine.begin() as conn:
        rows = conn.execute(text("""
            SELECT organization_id, principal_id,
                   phone_e164, id_proof_number, country, country_code, id_proof_type,
                   phone_ciphertext, phone_salt, phone_hmac,
                   id_proof_ciphertext, id_proof_salt, id_proof_hmac,
                   id_proof_fingerprint
            FROM organization_member_profiles
            WHERE phone_e164 IS NOT NULL OR id_proof_number IS NOT NULL
            FOR UPDATE
        """)).mappings().all()

        for row in rows:
            org = str(row["organization_id"])
            principal = str(row["principal_id"])
            updates = {}
            if row["phone_e164"] is not None and row["phone_ciphertext"] is None:
                protected = protect_profile_value(row["phone_e164"], "phone", org, principal)
                updates.update({"phone_ciphertext": protected["ciphertext"], "phone_salt": protected["salt"], "phone_hmac": protected["hmac"]})
            if row["id_proof_number"] is not None and row["id_proof_ciphertext"] is None:
                country_code = str(row["country_code"] or "").strip().upper()
                if not re.fullmatch(r"[A-Z]{2}", country_code):
                    try:
                        country_code = pycountry.countries.lookup(str(row["country"] or "")).alpha_2
                    except LookupError as exc:
                        raise RuntimeError(
                            "Cannot securely fingerprint a legacy ID proof without a valid country code."
                        ) from exc
                    updates["country_code"] = country_code
                try:
                    proof_type = normalize_id_proof_type(
                        country_code, str(row["id_proof_type"] or "")
                    )
                except ValueError as exc:
                    raise RuntimeError(
                        "Cannot securely fingerprint a legacy ID proof with an unsupported proof type."
                    ) from exc
                if proof_type != row["id_proof_type"]:
                    updates["id_proof_type"] = proof_type
                protected = protect_profile_value(
                    row["id_proof_number"], "id_proof", org, principal,
                    country_code=country_code, id_proof_type=proof_type,
                )
                updates.update({
                    "id_proof_ciphertext": protected["ciphertext"],
                    "id_proof_salt": protected["salt"],
                    "id_proof_hmac": protected["hmac"],
                    "id_proof_fingerprint": protected["fingerprint"],
                })
            if updates:
                assignments = ", ".join(f"{name}=:{name}" for name in updates)
                conn.execute(text(f"UPDATE organization_member_profiles SET {assignments} WHERE organization_id=:org AND principal_id=:principal"), {**updates, "org": org, "principal": principal})

        remaining = conn.execute(text("SELECT count(*) FROM organization_member_profiles WHERE phone_e164 IS NOT NULL OR id_proof_number IS NOT NULL")).scalar_one()
        if int(remaining):
            raise RuntimeError("Profile PII migration left plaintext values behind.")
        conn.exec_driver_sql("ALTER TABLE organization_member_profiles DROP COLUMN IF EXISTS phone_e164, DROP COLUMN IF EXISTS id_proof_number")
        conn.exec_driver_sql("DROP INDEX IF EXISTS idx_member_profiles_org_phone")


def verify_profile_security(engine) -> None:
    from firebase_authz.profile_crypto import verify_profile_pii_key

    verify_profile_pii_key()
    inspector = inspect(engine)
    if not inspector.has_table("organization_member_profiles"):
        raise RuntimeError("Employee profile table is missing.")
    required = {
        "organization_id", "principal_id", "full_name", "email",
        "email_verified_at", "phone_verified_at",
        "address_line1", "address_line2", "city", "state", "state_code",
        "postal_code", "country", "country_code", "id_proof_type",
        "id_proof_provided_at", "phone_ciphertext", "phone_salt",
        "phone_hmac", "id_proof_ciphertext", "id_proof_salt",
        "id_proof_hmac", "id_proof_fingerprint",
        "created_at", "updated_at",
    }
    actual = {
        column["name"]
        for column in inspector.get_columns("organization_member_profiles")
    }
    missing = sorted(required - actual)
    if missing:
        raise RuntimeError(
            "Employee profile columns are missing: " + ",".join(missing)
        )
    plaintext_columns = {"phone_e164", "id_proof_number"} & actual
    if plaintext_columns:
        raise RuntimeError(
            "Plaintext employee PII columns remain: " + ",".join(sorted(plaintext_columns))
        )
    with engine.connect() as conn:
        row = conn.execute(text("""
            SELECT c.relrowsecurity
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema()
              AND c.relname = 'organization_member_profiles'
        """)).one_or_none()
        if not row or not bool(row[0]):
            raise RuntimeError("Employee profile RLS is not enabled.")


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
    verify_assignment_indexes(indexes)


def _normalize_sql_expression(value: str) -> str:
    """Normalize PostgreSQL's harmless formatting/casts without losing token boundaries."""
    import re

    value = value.strip().lower().replace('"', "")
    value = re.sub(r"::(?:pg_catalog\.)?(?:text|varchar|character varying)\b", "", value)
    value = re.sub(r"\s+", "", value)
    while value.startswith("(") and value.endswith(")"):
        depth = 0
        encloses_all = True
        for position, character in enumerate(value):
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0 and position != len(value) - 1:
                    encloses_all = False
                    break
        if not encloses_all:
            break
        value = value[1:-1]
    return value


def _index_key_expressions(definition: str) -> list[str]:
    """Extract top-level index key expressions, respecting nested COALESCE parentheses."""
    import re

    match = re.search(r"\bon\s+.+?\s+using\s+\w+\s*\(", definition, re.IGNORECASE)
    if not match:
        raise RuntimeError("uq_active_assignment_context has an unreadable index definition.")
    start = match.end()
    depth = 1
    quote = None
    keys: list[str] = []
    segment_start = start
    index = start
    while index < len(definition):
        char = definition[index]
        if quote:
            if char == quote:
                if index + 1 < len(definition) and definition[index + 1] == quote:
                    index += 1
                else:
                    quote = None
        elif char in ("'", '"'):
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                keys.append(definition[segment_start:index].strip())
                return [_normalize_sql_expression(key) for key in keys]
        elif char == "," and depth == 1:
            keys.append(definition[segment_start:index].strip())
            segment_start = index + 1
        index += 1
    raise RuntimeError("uq_active_assignment_context has an unterminated key list.")


def verify_assignment_indexes(indexes: dict[str, str]) -> None:
    """Validate the exact active-assignment uniqueness contract created by migration 0008."""
    if "uq_active_manager_per_location" in indexes:
        raise RuntimeError(
            "Obsolete uq_active_manager_per_location index remains; migration 0033 must remove it."
        )

    definition = indexes.get("uq_active_assignment_context")
    if definition is None:
        raise RuntimeError("Missing uq_active_assignment_context.")
    import re

    if not re.search(r"^\s*create\s+unique\s+index\b", definition, re.IGNORECASE):
        raise RuntimeError("uq_active_assignment_context must be a unique index.")

    expected_keys = [
        "organization_id",
        "principal_id",
        "coalesce(location_id,'')",
        "coalesce(section_id,'')",
        "role_id",
    ]
    actual_keys = _index_key_expressions(definition)
    if actual_keys != expected_keys:
        missing = [key for key in expected_keys if key not in actual_keys]
        raise RuntimeError(
            "uq_active_assignment_context has incorrect assignment keys; "
            "expected organization_id, principal_id, COALESCE(location_id, ''), "
            "COALESCE(section_id, ''), role_id"
            + (("; missing " + ",".join(missing)) if missing else "")
        )

    predicate_match = re.search(r"\bwhere\b(.+)$", definition, re.IGNORECASE | re.DOTALL)
    if not predicate_match or _normalize_sql_expression(predicate_match.group(1)) != "status='active'":
        raise RuntimeError(
            "uq_active_assignment_context must apply exactly to rows with status = 'active'."
        )


def verify_assignment_index_schema(engine) -> None:
    """Read the live PostgreSQL index definitions and enforce the assignment contract."""
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT indexname, indexdef
            FROM pg_indexes
            WHERE schemaname = current_schema()
              AND tablename = 'organizational_assignments'
              AND indexname IN (
                  'uq_active_manager_per_location',
                  'uq_active_assignment_context'
              )
        """)).all()
    verify_assignment_indexes({row[0]: row[1] for row in rows})


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

        physical_schema = conn.execute(text("""
            SELECT 1
            FROM information_schema.schemata
            WHERE schema_name = 'managed_data'
        """)).scalar_one_or_none()
        if physical_schema is None:
            raise RuntimeError("managed_data schema is missing.")

        version_columns = {
            column["name"]
            for column in inspect(engine).get_columns("dataset_versions")
        }
        if "data_table_name" not in version_columns:
            raise RuntimeError("dataset_versions.data_table_name is missing.")

        bad_physical_rls = conn.execute(text("""
            SELECT c.relname
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'managed_data'
              AND c.relkind = 'r'
              AND c.relrowsecurity = false
            LIMIT 1
        """)).scalar_one_or_none()
        if bad_physical_rls is not None:
            raise RuntimeError(
                "RLS is not enabled on managed_data table: " + str(bad_physical_rls)
            )

def verify_supabase_function_security(engine) -> None:
    """Fail closed if privileged trigger functions remain exposed as public RPCs."""
    expected_search_paths = {
        "enforce_single_active_branch_assignment": 'search_path=""',
        "reject_duplicate_employee_id_proof": 'search_path=""',
        "insightflow_cleanup_deleted_auth_user": 'search_path=""',
        "insightflow_cleanup_orphaned_branch_organization": 'search_path=""',
        "rls_auto_enable": "search_path=pg_catalog",
    }
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT
                p.proname,
                COALESCE(array_to_string(p.proconfig, ','), '') AS settings,
                has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
                has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
                has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
                has_function_privilege('supabase_auth_admin', p.oid, 'EXECUTE') AS auth_admin_execute
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname = ANY(:function_names)
        """), {"function_names": sorted(expected_search_paths)}).mappings().all()

    found = {row["proname"]: row for row in rows}
    missing = sorted(set(expected_search_paths) - set(found))
    if missing:
        raise RuntimeError("Supabase security trigger functions are missing: " + ",".join(missing))

    for name, expected_setting in expected_search_paths.items():
        row = found[name]
        if expected_setting not in (row["settings"] or ""):
            raise RuntimeError(f"Unsafe or unset search_path on public.{name}().")
        if row["anon_execute"] or row["authenticated_execute"] or row["service_role_execute"]:
            raise RuntimeError(f"Public API execution remains enabled for public.{name}().")

    if not found["insightflow_cleanup_deleted_auth_user"]["auth_admin_execute"]:
        raise RuntimeError("Supabase Auth service lost EXECUTE on its account-cleanup trigger function.")


def run_migrations() -> None:
    """Apply and verify pending production PostgreSQL migrations.

    Safe to call during application startup: migrations are versioned,
    transactional per file, and serialized with a PostgreSQL advisory lock.
    """
    engine = connect()
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    apply_pending(engine)
    migrate_profile_pii(engine)
    final_tables, _ = inspect_database(engine)
    missing = sorted(EXPECTED_TABLES - final_tables)
    if missing:
        raise RuntimeError("Required authorization tables are missing: " + ",".join(missing))
    verify_organizational_structure(engine)
    verify_assignment_index_schema(engine)
    verify_profile_security(engine)
    verify_employee_id_allocator(engine)
    verify_managed_dataset_security(engine)
    verify_supabase_function_security(engine)


def verify_employee_id_allocator(engine) -> None:
    inspector = inspect(engine)
    required = {"organization_id", "last_issued", "updated_at"}
    actual = {
        column["name"]
        for column in inspector.get_columns("organization_employee_id_counters")
    }
    missing = sorted(required - actual)
    if missing:
        raise RuntimeError(
            "Employee ID counter columns are missing: " + ",".join(missing)
        )
    with engine.connect() as conn:
        row = conn.execute(text("""
            SELECT c.relrowsecurity
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema()
              AND c.relname = 'organization_employee_id_counters'
        """)).one_or_none()
    if not row or not bool(row[0]):
        raise RuntimeError("Employee ID counter RLS is not enabled.")


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
        verify_assignment_index_schema(engine)
        verify_profile_security(engine)
        verify_employee_id_allocator(engine)
        verify_managed_dataset_security(engine)
        verify_supabase_function_security(engine)
        print("SUPABASE_FUNCTION_SECURITY=PASS")
        print("ORGANIZATIONAL_STRUCTURE=PASS")
        print("ASSIGNMENT_INDEXES=PASS")
        print("REQUIRED_TABLES=PASS")
    if missing:
        print("MISSING_TABLE_COUNT=" + str(len(missing)))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
