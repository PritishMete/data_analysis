import os
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text


MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "migrations"
    / "0038_supabase_function_privilege_hardening.sql"
)


def test_supabase_function_hardening_migration_on_disposable_postgres():
    database_url = os.environ.get("AUTHZ_TEST_DATABASE_URL", "").strip()
    if not database_url:
        pytest.skip("AUTHZ_TEST_DATABASE_URL is only configured in the disposable PostgreSQL CI job.")

    engine = create_engine(database_url, future=True)
    try:
        with engine.begin() as conn:
            conn.exec_driver_sql("""
                DO $roles$
                DECLARE
                    role_name text;
                BEGIN
                    FOREACH role_name IN ARRAY ARRAY[
                        'anon', 'authenticated', 'service_role', 'supabase_auth_admin'
                    ]
                    LOOP
                        IF NOT EXISTS (
                            SELECT 1 FROM pg_roles WHERE rolname = role_name
                        ) THEN
                            EXECUTE format('CREATE ROLE %%I NOLOGIN', role_name);
                        END IF;
                    END LOOP;
                END;
                $roles$;
            """)

            conn.exec_driver_sql("""
                CREATE OR REPLACE FUNCTION public.enforce_single_active_branch_assignment()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RETURN NEW;
                END;
                $$;

                CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RETURN NEW;
                END;
                $$;

                CREATE OR REPLACE FUNCTION public.insightflow_cleanup_deleted_auth_user()
                RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
                SET search_path = '' AS $$
                BEGIN
                    RETURN OLD;
                END;
                $$;

                CREATE OR REPLACE FUNCTION public.insightflow_cleanup_orphaned_branch_organization()
                RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
                SET search_path = '' AS $$
                BEGIN
                    RETURN OLD;
                END;
                $$;

                CREATE OR REPLACE FUNCTION public.rls_auto_enable()
                RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
                SET search_path = pg_catalog AS $$
                BEGIN
                    RETURN;
                END;
                $$;

                GRANT EXECUTE ON FUNCTION
                    public.enforce_single_active_branch_assignment(),
                    public.reject_duplicate_employee_id_proof(),
                    public.insightflow_cleanup_deleted_auth_user(),
                    public.insightflow_cleanup_orphaned_branch_organization(),
                    public.rls_auto_enable()
                TO PUBLIC, anon, authenticated, service_role;

                GRANT EXECUTE ON FUNCTION public.insightflow_cleanup_deleted_auth_user()
                    TO supabase_auth_admin;
            """)

            conn.exec_driver_sql(MIGRATION.read_text(encoding="utf-8"))

            rows = conn.execute(text("""
                SELECT
                    p.proname,
                    p.prosecdef,
                    COALESCE(array_to_string(p.proconfig, ','), '') AS settings,
                    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
                    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
                    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
                    has_function_privilege('supabase_auth_admin', p.oid, 'EXECUTE') AS auth_admin_execute
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = ANY(:names)
            """), {"names": [
                "enforce_single_active_branch_assignment",
                "reject_duplicate_employee_id_proof",
                "insightflow_cleanup_deleted_auth_user",
                "insightflow_cleanup_orphaned_branch_organization",
                "rls_auto_enable",
            ]}).mappings().all()

        found = {row["proname"]: row for row in rows}
        assert len(found) == 5

        for row in found.values():
            assert row["anon_execute"] is False
            assert row["authenticated_execute"] is False
            assert row["service_role_execute"] is False

        assert 'search_path=""' in found["enforce_single_active_branch_assignment"]["settings"]
        assert 'search_path=""' in found["reject_duplicate_employee_id_proof"]["settings"]
        assert 'search_path=""' in found["insightflow_cleanup_deleted_auth_user"]["settings"]
        assert 'search_path=""' in found["insightflow_cleanup_orphaned_branch_organization"]["settings"]
        assert "search_path=pg_catalog" in found["rls_auto_enable"]["settings"]

        assert found["insightflow_cleanup_deleted_auth_user"]["prosecdef"] is True
        assert found["insightflow_cleanup_orphaned_branch_organization"]["prosecdef"] is True
        assert found["rls_auto_enable"]["prosecdef"] is True
        assert found["insightflow_cleanup_deleted_auth_user"]["auth_admin_execute"] is True
    finally:
        engine.dispose()
