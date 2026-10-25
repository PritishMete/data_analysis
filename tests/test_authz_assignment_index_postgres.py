"""Full migration-chain tests using a disposable PostgreSQL database only.

The only database URL read by this module is AUTHZ_TEST_DATABASE_URL. The CI
job points it at its local postgres:16 service and asserts the test database
name before pytest is invoked. Supabase-managed auth/storage schemas and roles
are provisioned as a test baseline; application-owned public tables are created
only by the real migration runner.
"""

import os
from pathlib import Path
from unittest.mock import patch

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import IntegrityError

from tools import run_authz_migrations as runner


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations"
DATABASE_URL = os.environ.get("AUTHZ_TEST_DATABASE_URL", "").strip()

pytestmark = pytest.mark.skipif(
    not DATABASE_URL.startswith(("postgresql://", "postgresql+psycopg://")),
    reason="Requires the disposable PostgreSQL AUTHZ_TEST_DATABASE_URL supplied by CI.",
)


def _assert_disposable_test_url(url: str) -> None:
    parsed = make_url(url)
    assert parsed.database == "insightflow_authz_test", (
        "PostgreSQL integration tests may only use the dedicated test database."
    )
    assert parsed.host in {"localhost", "127.0.0.1", "::1", "postgres"}, (
        "PostgreSQL integration tests may only use a local CI database service."
    )


@pytest.fixture()
def postgres_engine():
    _assert_disposable_test_url(DATABASE_URL)
    engine = create_engine(DATABASE_URL, future=True)
    with engine.begin() as conn:
        # This service DB is disposable. Reset it to an empty PostgreSQL public
        # schema plus the Supabase-managed prerequisites that exist before app
        # migrations are run. Never read DATABASE_URL or production secrets.
        conn.execute(text("DROP SCHEMA IF EXISTS managed_data CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS private CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS storage CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS auth CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
        conn.execute(text("GRANT ALL ON SCHEMA public TO postgres"))

        conn.execute(text("""
            DO $roles$
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
                    EXECUTE 'CREATE ROLE anon NOLOGIN';
                END IF;
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
                    EXECUTE 'CREATE ROLE authenticated NOLOGIN';
                END IF;
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
                    EXECUTE 'CREATE ROLE service_role NOLOGIN';
                END IF;
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
                    EXECUTE 'CREATE ROLE supabase_auth_admin NOLOGIN';
                END IF;
            END
            $roles$;
        """))

        conn.execute(text("CREATE SCHEMA auth"))
        conn.execute(text("CREATE TABLE auth.users (id UUID PRIMARY KEY)"))
        conn.execute(text("""
            CREATE FUNCTION auth.uid() RETURNS UUID
            LANGUAGE SQL STABLE
            AS $$ SELECT NULL::UUID $$
        """))
        conn.execute(text("GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role, supabase_auth_admin"))
        conn.execute(text("GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role"))

        conn.execute(text("CREATE SCHEMA storage"))
        conn.execute(text("""
            CREATE TABLE storage.buckets (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                public BOOLEAN NOT NULL DEFAULT FALSE,
                file_size_limit BIGINT,
                allowed_mime_types TEXT[]
            )
        """))
        conn.execute(text("""
            CREATE TABLE storage.objects (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                bucket_id TEXT,
                name TEXT,
                metadata JSONB
            )
        """))
        conn.execute(text("ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY"))
        conn.execute(text("GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role"))
        conn.execute(text("GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated"))
    try:
        yield engine
    finally:
        engine.dispose()


def _history(engine):
    with engine.connect() as conn:
        return conn.execute(text("""
            SELECT version, applied_at
            FROM public.insightflow_schema_migrations
            ORDER BY version
        """)).all()


def _read_assignment_indexes(engine):
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
            ORDER BY indexname
        """)).all()
    return {row[0]: row[1] for row in rows}


def _seed_manager_assignments(engine):
    with engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO principals (principal_id)
            VALUES ('person-a'), ('person-b')
        """))
        conn.execute(text("""
            INSERT INTO organizations (organization_id, name, created_by_principal_id)
            VALUES ('org-a', 'Test Org', 'person-a')
        """))
        conn.execute(text("""
            INSERT INTO workspaces (workspace_id, organization_id)
            VALUES ('workspace-a', 'org-a')
        """))
        conn.execute(text("""
            INSERT INTO organization_members
                (organization_id, workspace_id, principal_id, employee_id)
            VALUES
                ('org-a', 'workspace-a', 'person-a', 'EMP-A'),
                ('org-a', 'workspace-a', 'person-b', 'EMP-B')
        """))
        conn.execute(text("""
            INSERT INTO locations
                (location_id, organization_id, name, branch_identifier)
            VALUES ('branch-a', 'org-a', 'Branch A', 'BRANCH-A')
        """))
        conn.execute(text("""
            INSERT INTO organizational_assignments
                (assignment_id, organization_id, principal_id, location_id, role_id, status)
            VALUES
                ('assignment-a', 'org-a', 'person-a', 'branch-a', 'manager', 'active'),
                ('assignment-b', 'org-a', 'person-b', 'branch-a', 'manager', 'active')
        """))


def test_full_production_migration_runner_and_second_startup_are_idempotent(
    postgres_engine, monkeypatch
):
    # Replace only the connection factory with the isolated CI service engine.
    # migration_files(), apply_pending(), and all verifier functions remain real.
    monkeypatch.setattr(runner, "connect", lambda: postgres_engine)

    import main
    from core import db as core_db

    # main imports init_db by name, but the actual function uses core.db's
    # module-level engine. Bind that engine to the disposable PostgreSQL
    # service so this test exercises the real follow-up application DB setup.
    monkeypatch.setattr(core_db, "engine", postgres_engine)
    actual_init_db = main.init_db
    startup_calls = []
    expected_versions = {path.stem for path in runner.migration_files()}

    def verified_application_db_init():
        # This assertion runs at the exact point main.py calls init_db; all
        # authz migrations and their history must already have committed.
        assert {row.version for row in _history(postgres_engine)} == expected_versions
        startup_calls.append("application-db-init")
        actual_init_db()

    monkeypatch.setattr(main, "init_db", verified_application_db_init)
    test_environment = {
        "AUTHZ_PERSISTENCE_PROVIDER": "supabase",
        "DATABASE_URL": DATABASE_URL,
    }

    # The production startup function runs the complete repository migration
    # chain before invoking the application's follow-up DB initializer.
    with patch.dict(os.environ, test_environment, clear=False):
        main._initialize_production_database()

    assert startup_calls == ["application-db-init"]

    # Every actual production-runner migration file should be represented in
    # history, including both 0011, both 0014, and both 0030 migrations.
    expected_versions = {path.stem for path in runner.migration_files()}
    first_history = _history(postgres_engine)
    assert {row.version for row in first_history} == expected_versions
    assert all(row.applied_at is not None for row in first_history)
    assert len(first_history) == len(expected_versions)

    # run_migrations calls the same verifier functions used by production.
    indexes = _read_assignment_indexes(postgres_engine)
    assert "uq_active_manager_per_location" not in indexes
    assert "uq_active_assignment_context" in indexes
    runner.verify_organizational_structure(postgres_engine)
    runner.verify_profile_security(postgres_engine)
    runner.verify_employee_id_allocator(postgres_engine)
    runner.verify_managed_dataset_security(postgres_engine)

    # Assert supporting authorization objects created outside the runner's
    # compact EXPECTED_TABLES set, along with the external schemas/triggers.
    from sqlalchemy import inspect

    public_tables = set(inspect(postgres_engine).get_table_names())
    assert {
        "authorization_requests",
        "working_copy_assignments",
        "management_assignment_requests",
        "organization_employee_id_counters",
        "datasets",
        "dataset_versions",
        "dataset_columns",
        "dataset_rows",
        "dataset_change_proposals",
    } <= public_tables

    with postgres_engine.connect() as conn:
        proposal_security = conn.execute(text("""
            SELECT c.relrowsecurity,
                   EXISTS (
                     SELECT 1 FROM pg_policies p
                     WHERE p.schemaname='public' AND p.tablename='dataset_change_proposals'
                   ) AS has_client_policy
            FROM pg_class c
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relname='dataset_change_proposals'
        """)).one()
        assert proposal_security.relrowsecurity is True
        assert proposal_security.has_client_policy is False
        proposal_columns = {
            row[0] for row in conn.execute(text("""
                SELECT column_name FROM information_schema.columns
                WHERE table_schema='public' AND table_name='dataset_change_proposals'
            """))
        }
        assert {
            "proposal_id", "organization_id", "workspace_id", "dataset_id",
            "location_id", "candidate_version_pk", "submitted_by_principal_id",
            "base_version_id", "status", "submitted_at", "reviewed_by_principal_id",
            "reviewed_at", "decision_note", "file_hash", "file_size",
        } <= proposal_columns
        pending_index = conn.execute(text("""
            SELECT indexdef FROM pg_indexes
            WHERE schemaname='public' AND indexname='uq_dataset_change_pending_content'
        """)).scalar_one_or_none()
        assert pending_index is not None
        assert "WHERE (status = 'pending'::text)" in pending_index or "WHERE status = 'pending'::text" in pending_index
        branch_fk = conn.execute(text("""
            SELECT 1 FROM pg_constraint
            WHERE conname='fk_dataset_change_proposal_branch' AND contype='f'
        """)).scalar_one_or_none()
        assert branch_fk == 1
    with postgres_engine.connect() as conn:
        schemas = {
            row[0] for row in conn.execute(text("""
                SELECT schema_name FROM information_schema.schemata
                WHERE schema_name IN ('auth', 'storage', 'private', 'managed_data')
            """))
        }
        assert schemas == {"auth", "storage", "private", "managed_data"}
        trigger_names = {
            row[0] for row in conn.execute(text("""
                SELECT t.tgname
                FROM pg_trigger t
                JOIN pg_class c ON c.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE NOT t.tgisinternal
            """))
        }
        assert {
            "insightflow_cleanup_deleted_auth_user",
            "organizational_assignments_single_active_branch",
            "insightflow_cleanup_orphaned_branch_organization",
        } <= trigger_names

    # Verify the history-aware apply path reports every version as completed.
    applied_again, already_applied = runner.apply_pending(postgres_engine)
    assert applied_again == []
    assert set(already_applied) == expected_versions
    assert {row.version for row in _history(postgres_engine)} == expected_versions

    # Run the actual production initialization path a second time. It must not
    # reapply completed SQL and must still complete before the app DB init.
    with patch.dict(os.environ, test_environment, clear=False):
        main._initialize_production_database()
    assert startup_calls == ["application-db-init", "application-db-init"]
    assert {row.version for row in _history(postgres_engine)} == expected_versions

    # The real migrated constraints allow two principals to be active Managers
    # at the same location, but still reject a duplicate active context.
    _seed_manager_assignments(postgres_engine)
    with postgres_engine.connect() as conn:
        managers = conn.execute(text("""
            SELECT count(*)
            FROM organizational_assignments
            WHERE organization_id = 'org-a'
              AND location_id = 'branch-a'
              AND role_id = 'manager'
              AND status = 'active'
        """)).scalar_one()
    assert managers == 2

    with pytest.raises(IntegrityError):
        with postgres_engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO organizational_assignments
                    (assignment_id, organization_id, principal_id, location_id, role_id, status)
                VALUES ('assignment-a-duplicate', 'org-a', 'person-a', 'branch-a', 'manager', 'active')
            """))
