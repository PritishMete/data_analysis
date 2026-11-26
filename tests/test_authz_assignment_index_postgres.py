"""Full migration-chain tests using a disposable PostgreSQL database only.

The only database URL read by this module is AUTHZ_TEST_DATABASE_URL. The CI
job points it at its local postgres:16 service and asserts the test database
name before pytest is invoked. Supabase-managed auth/storage schemas and roles
are provisioned as a test baseline; application-owned public tables are created
only by the real migration runner.
"""

import asyncio
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
TEST_PROFILE_PII_KEY = "0000000000000000000000000000000000000000000000000000000000000000"

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
def postgres_engine(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_PROFILE_PII_KEY", TEST_PROFILE_PII_KEY)
    _assert_disposable_test_url(DATABASE_URL)
    engine = create_engine(DATABASE_URL, future=True)
    with engine.begin() as conn:
        # This service DB is disposable. Reset it to an empty PostgreSQL public
        # schema plus the Supabase-managed prerequisites that exist before app
        # migrations are run. Never read DATABASE_URL or production secrets.
        conn.execute(text("DROP SCHEMA IF EXISTS managed_data CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS private CASCADE"))
        conn.execute(text("DROP SCHEMA IF EXISTS excel_handoff CASCADE"))
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

        # Supabase owns this event-trigger function outside the app migration
        # chain. Model the production prerequisite so the follow-up migration
        # can revoke its default PostgREST execution grants in this disposable DB.
        conn.execute(text("""
            CREATE FUNCTION public.rls_auto_enable()
            RETURNS event_trigger
            LANGUAGE plpgsql
            SECURITY DEFINER
            SET search_path TO 'pg_catalog'
            AS $$
            BEGIN
                RETURN;
            END;
            $$
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
        "manager_dataset_upload_grants",
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
        assert conn.execute(text("SELECT has_schema_privilege('anon', 'managed_data', 'USAGE')")).scalar_one() is False


        assert conn.execute(text("SELECT has_schema_privilege('authenticated', 'managed_data', 'USAGE')")).scalar_one() is False
        ready_policies = {
            row[0]: row[1]
            for row in conn.execute(text("""
                SELECT tablename, qual FROM pg_policies
                WHERE schemaname='public'
                  AND tablename IN ('dataset_versions', 'dataset_columns', 'dataset_rows')
                  AND policyname IN (
                    'managed_dataset_versions_select',
                    'managed_dataset_columns_select',
                    'managed_dataset_rows_select'
                  )
            """))
        }
        assert set(ready_policies) == {'dataset_versions', 'dataset_columns', 'dataset_rows'}
        assert all(qual and 'ready' in qual.lower() for qual in ready_policies.values())
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
            "dataset_kind", "upload_grant_id",
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

        grant_security = conn.execute(text("""
            SELECT c.relrowsecurity,
                   EXISTS (
                     SELECT 1 FROM pg_policies p
                     WHERE p.schemaname='public'
                       AND p.tablename='manager_dataset_upload_grants'
                   ) AS has_client_policy
            FROM pg_class c
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relname='manager_dataset_upload_grants'
        """)).one()
        assert grant_security.relrowsecurity is True
        assert grant_security.has_client_policy is False
        assert conn.execute(text(
            "SELECT has_table_privilege('anon', 'public.manager_dataset_upload_grants', 'SELECT')"
        )).scalar_one() is False
        assert conn.execute(text(
            "SELECT has_table_privilege('authenticated', 'public.manager_dataset_upload_grants', 'INSERT')"
        )).scalar_one() is False
        assert conn.execute(text("""
            SELECT EXISTS (
                SELECT 1 FROM role_permissions
                WHERE role_id='manager' AND permission_id='dataset.propose'
            )
        """)).scalar_one() is False
        grant_index = conn.execute(text("""
            SELECT indexdef FROM pg_indexes
            WHERE schemaname='public' AND indexname='uq_manager_upload_grant_active'
        """)).scalar_one_or_none()
        assert grant_index is not None and "revoked_at IS NULL" in grant_index
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


@pytest.mark.parametrize(
    ("index_change", "expected_error"),
    [
        (
            "DROP INDEX public.uq_active_assignment_context",
            "Missing uq_active_assignment_context",
        ),
        (
            "DROP INDEX public.uq_active_assignment_context; "
            "CREATE UNIQUE INDEX uq_active_manager_per_location "
            "ON public.organizational_assignments (organization_id, location_id) "
            "WHERE status = 'active' AND role_id = 'manager'",
            "Obsolete uq_active_manager_per_location",
        ),
    ],
)
def test_production_migration_runner_rejects_invalid_assignment_index(
    postgres_engine, monkeypatch, index_change, expected_error
):
    """The actual startup runner must fail closed on stale/missing live indexes."""
    monkeypatch.setattr(runner, "connect", lambda: postgres_engine)
    runner.run_migrations()

    with postgres_engine.begin() as conn:
        # Only mutate this disposable PostgreSQL fixture after a valid migration
        # chain has been installed; never point this fixture at production.
        for statement in index_change.split("; "):
            conn.exec_driver_sql(statement)

    with pytest.raises(RuntimeError, match=expected_error):
        runner.run_migrations()


def test_fastapi_lifespan_runs_required_initialization_before_serving(monkeypatch):
    import main

    calls = []
    monkeypatch.setattr(
        main, "_initialize_production_database", lambda: calls.append("initialized")
    )

    async def exercise_lifespan():
        async with main.app.router.lifespan_context(main.app):
            assert calls == ["initialized"]

    asyncio.run(exercise_lifespan())
    assert calls == ["initialized"]


def test_profile_pii_legacy_backfill_and_duplicate_proof_guard(postgres_engine, monkeypatch):
    """Legacy plaintext values are encrypted, removed, and remain duplicate-checkable."""
    monkeypatch.setattr(runner, "connect", lambda: postgres_engine)
    runner.run_migrations()
    _seed_manager_assignments(postgres_engine)

    with postgres_engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO organization_member_profiles
                (organization_id, principal_id, full_name, email, country, country_code,
                 id_proof_type, id_proof_provided_at)
            VALUES
                ('org-a', 'person-a', 'Legacy Person', 'legacy@example.com',
                 'India', 'IN', 'Passport', now())
        """))
        # Recreate the old schema columns to simulate a pre-0039 production row.
        conn.exec_driver_sql("""
            ALTER TABLE organization_member_profiles
              ADD COLUMN phone_e164 TEXT,
              ADD COLUMN id_proof_number TEXT
        """)
        conn.execute(text("""
            UPDATE organization_member_profiles
            SET phone_e164='+919876543210',
                id_proof_number='AB-1234567'
            WHERE organization_id='org-a' AND principal_id='person-a'
        """))

    runner.migrate_profile_pii(postgres_engine)

    from firebase_authz.profile_crypto import (
        protect_profile_value,
        reveal_profile_value,
    )
    from sqlalchemy import inspect

    columns = {
        item["name"]
        for item in inspect(postgres_engine).get_columns("organization_member_profiles")
    }
    assert "phone_e164" not in columns
    assert "id_proof_number" not in columns

    with postgres_engine.connect() as conn:
        profile = conn.execute(text("""
            SELECT phone_ciphertext, phone_salt, phone_hmac,
                   id_proof_ciphertext, id_proof_salt, id_proof_hmac,
                   id_proof_fingerprint, id_proof_type
            FROM organization_member_profiles
            WHERE organization_id='org-a' AND principal_id='person-a'
        """)).mappings().one()

    assert profile["phone_ciphertext"] is not None
    assert profile["id_proof_ciphertext"] is not None
    assert profile["phone_salt"] != profile["id_proof_salt"]
    assert reveal_profile_value(
        profile["phone_ciphertext"], profile["phone_salt"], profile["phone_hmac"],
        "phone", "org-a", "person-a",
    ) == "+919876543210"
    assert reveal_profile_value(
        profile["id_proof_ciphertext"], profile["id_proof_salt"], profile["id_proof_hmac"],
        "id_proof", "org-a", "person-a",
    ) == "AB-1234567"
    assert profile["id_proof_type"] == "passport"

    phone_data = protect_profile_value(
        "+919876543211", "phone", "org-a", "person-b"
    )
    proof_data = protect_profile_value(
        "AB1234567", "id_proof", "org-a", "person-b",
        country_code="IN", id_proof_type="passport",
    )
    assert proof_data["salt"] != profile["id_proof_salt"]
    assert proof_data["fingerprint"] == profile["id_proof_fingerprint"]

    with pytest.raises(IntegrityError):
        with postgres_engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO organization_member_profiles
                    (organization_id, principal_id, full_name, email, country, country_code,
                     id_proof_type, phone_ciphertext, phone_salt, phone_hmac,
                     id_proof_ciphertext, id_proof_salt, id_proof_hmac,
                     id_proof_fingerprint, id_proof_provided_at)
                VALUES
                    ('org-a', 'person-b', 'Second Person', 'second@example.com',
                     'India', 'IN', 'passport', :phone_ciphertext, :phone_salt, :phone_hmac,
                     :id_ciphertext, :id_salt, :id_hmac, :fingerprint, now())
            """), {
                "phone_ciphertext": phone_data["ciphertext"],
                "phone_salt": phone_data["salt"],
                "phone_hmac": phone_data["hmac"],
                "id_ciphertext": proof_data["ciphertext"],
                "id_salt": proof_data["salt"],
                "id_hmac": proof_data["hmac"],
                "fingerprint": proof_data["fingerprint"],
            })


def test_diagnostic_session_claim_and_scope_isolation_on_disposable_postgres(
    postgres_engine, monkeypatch
):
    monkeypatch.setattr(runner, "connect", lambda: postgres_engine)
    runner.run_migrations()
    claim_hash = "a" * 64
    with postgres_engine.begin() as conn:
        conn.execute(text("INSERT INTO principals(principal_id) VALUES ('diag-a'),('diag-b')"))
        conn.execute(text("INSERT INTO organizations(organization_id,name,created_by_principal_id) VALUES ('diag-org-a','A','diag-a'),('diag-org-b','B','diag-b')"))
        conn.execute(text("INSERT INTO workspaces(workspace_id,organization_id) VALUES ('diag-ws-a','diag-org-a'),('diag-ws-b','diag-org-b')"))
        conn.execute(text("""INSERT INTO organization_members(organization_id,workspace_id,principal_id,employee_id)
            VALUES ('diag-org-a','diag-ws-a','diag-a','DA'),('diag-org-b','diag-ws-b','diag-b','DB')"""))
        conn.execute(text("INSERT INTO diagnostic_sessions(session_id,claim_token_hash,expires_at) VALUES ('diag-session',:hash,now()+interval '15 minutes')"), {"hash": claim_hash})
        conn.execute(text("""INSERT INTO diagnostic_events(event_id,session_id,correlation_id,category,status,payload)
            VALUES ('diag-event','diag-session','corr-a','auth_stage','ok','{}')"""))
        assert conn.execute(text("SELECT claim_token_hash IS NOT NULL FROM diagnostic_sessions WHERE session_id='diag-session'")).scalar_one() is True
        assert conn.execute(text("SELECT count(*) FROM diagnostic_events WHERE organization_id='diag-org-b'")).scalar_one() == 0
        conn.execute(text("""UPDATE diagnostic_sessions SET user_principal_id='diag-a',organization_id='diag-org-a',claimed_at=now(),claim_token_hash=NULL
            WHERE session_id='diag-session' AND claim_token_hash=:hash AND claimed_at IS NULL AND expires_at>now()"""), {"hash": claim_hash})
        conn.execute(text("UPDATE diagnostic_events SET organization_id='diag-org-a',user_principal_id='diag-a' WHERE session_id='diag-session' AND organization_id IS NULL"))
        assert conn.execute(text("SELECT claim_token_hash IS NULL FROM diagnostic_sessions WHERE session_id='diag-session'")).scalar_one() is True
        second = conn.execute(text("""UPDATE diagnostic_sessions SET claimed_at=now(),claim_token_hash=NULL
            WHERE session_id='diag-session' AND claim_token_hash=:hash AND claimed_at IS NULL"""), {"hash": claim_hash})
        assert second.rowcount == 0
        assert conn.execute(text("SELECT count(*) FROM diagnostic_events WHERE organization_id='diag-org-b'")).scalar_one() == 0
        assert conn.execute(text("SELECT count(*) FROM diagnostic_events WHERE organization_id='diag-org-a'")).scalar_one() == 1
        conn.execute(text("INSERT INTO diagnostic_sessions(session_id,claim_token_hash,expires_at) VALUES ('expired-session',:hash,now()-interval '1 minute')"), {"hash": claim_hash})
        expired = conn.execute(text("""UPDATE diagnostic_sessions SET claimed_at=now(),claim_token_hash=NULL
            WHERE session_id='expired-session' AND claim_token_hash=:hash AND claimed_at IS NULL AND expires_at>now()"""), {"hash": claim_hash})
        assert expired.rowcount == 0


def test_diagnostic_route_functions_use_disposable_postgres_for_claim_and_events(
    postgres_engine, monkeypatch
):
    monkeypatch.setattr(runner, "connect", lambda: postgres_engine)
    runner.run_migrations()
    from sqlalchemy.orm import sessionmaker
    from firebase_authz import admin_diagnostics as diagnostics

    monkeypatch.setattr(diagnostics, "SessionLocal", sessionmaker(bind=postgres_engine, future=True))
    subject = "route-subject"
    with postgres_engine.begin() as conn:
        conn.execute(text("INSERT INTO principals(principal_id) VALUES ('route-principal')"))
        conn.execute(text("INSERT INTO organizations(organization_id,name,created_by_principal_id) VALUES ('route-org','Route','route-principal')"))
        conn.execute(text("INSERT INTO workspaces(workspace_id,organization_id) VALUES ('route-ws','route-org')"))
        conn.execute(text("INSERT INTO organization_members(organization_id,workspace_id,principal_id,employee_id) VALUES ('route-org','route-ws','route-principal','R1')"))
        conn.execute(text("INSERT INTO identity_bindings(provider,provider_subject,principal_id) VALUES ('supabase',:subject,'route-principal')"), {"subject": subject})

    created = diagnostics.create_session()
    item = diagnostics.EventIn(session_id=created["support_reference"], claim_secret=created["claim_secret"], correlation_id="route-correlation", category="office_dialog_open", status="started", payload={"stage": "office_dialog_open"})
    assert diagnostics.anonymous_event(item) == {"accepted": True}
    with pytest.raises(Exception):
        diagnostics.anonymous_event(diagnostics.EventIn(session_id=created["support_reference"], claim_secret=created["claim_secret"], correlation_id="bad", category="stage", status="failed", payload={"access_token": "Bearer eyJsecret"}))
    monkeypatch.setattr(diagnostics, "_claims", lambda _: {"sub": subject, "email_verified": True})
    assert diagnostics.claim_session(diagnostics.SessionClaim(session_id=created["support_reference"], claim_secret=created["claim_secret"]), "Bearer route-token") == {"claimed": True}
    with pytest.raises(Exception):
        diagnostics.claim_session(diagnostics.SessionClaim(session_id=created["support_reference"], claim_secret=created["claim_secret"]), "Bearer route-token")
    with postgres_engine.connect() as conn:
        row = conn.execute(text("SELECT claim_token_hash,organization_id,user_principal_id FROM diagnostic_sessions WHERE session_id=:session"), {"session": created["support_reference"]}).mappings().one()
        assert row["claim_token_hash"] is None
        assert row["organization_id"] == "route-org"
        assert row["user_principal_id"] == "route-principal"
        assert conn.execute(text("SELECT organization_id,user_principal_id FROM diagnostic_events WHERE session_id=:session"), {"session": created["support_reference"]}).one() == ("route-org", "route-principal")

    with pytest.raises(Exception):
        diagnostics.anonymous_event(diagnostics.EventIn(session_id=created["support_reference"], claim_secret="x" * 48, correlation_id="bad", category="stage", status="failed"))


def test_diagnostic_http_endpoints_use_disposable_postgres(
    postgres_engine, monkeypatch
):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from sqlalchemy.orm import sessionmaker
    from firebase_authz import admin_diagnostics as diagnostics

    runner.run_migrations()
    monkeypatch.setattr(diagnostics, "SessionLocal", sessionmaker(bind=postgres_engine, future=True))
    with postgres_engine.begin() as conn:
        conn.execute(text("INSERT INTO principals(principal_id) VALUES ('http-principal')"))
        conn.execute(text("INSERT INTO organizations(organization_id,name,created_by_principal_id) VALUES ('http-org','HTTP','http-principal')"))
        conn.execute(text("INSERT INTO workspaces(workspace_id,organization_id) VALUES ('http-ws','http-org')"))
        conn.execute(text("INSERT INTO organization_members(organization_id,workspace_id,principal_id,employee_id) VALUES ('http-org','http-ws','http-principal','H1')"))
        conn.execute(text("INSERT INTO identity_bindings(provider,provider_subject,principal_id) VALUES ('supabase','http-subject','http-principal')"))
    app = FastAPI()
    app.include_router(diagnostics.diagnostic_router)
    with TestClient(app) as client:
        created = client.post("/v1/diagnostics/sessions").raise_for_status().json()
        session_id = created["support_reference"]
        secret = created["claim_secret"]
        event = {"session_id": session_id, "claim_secret": secret, "correlation_id": "http-correlation", "category": "office_dialog_open", "status": "started", "payload": {"stage": "office_dialog_open"}}
        assert client.post("/v1/diagnostics/events", json=event).status_code == 200
        bad = dict(event, claim_secret="x" * 48)
        assert client.post("/v1/diagnostics/events", json=bad).status_code == 403
        sensitive = dict(event, payload={"access_token": "Bearer eyJsecret"})
        assert client.post("/v1/diagnostics/events", json=sensitive).status_code == 422
        monkeypatch.setattr(diagnostics, "_claims", lambda _: {"sub": "http-subject", "email_verified": True})
        headers = {"Authorization": "Bearer test-token"}
        assert client.post("/v1/diagnostics/sessions/claim", json={"session_id": session_id, "claim_secret": secret}, headers=headers).status_code == 200
        assert client.post("/v1/diagnostics/sessions/claim", json={"session_id": session_id, "claim_secret": secret}, headers=headers).status_code == 403
