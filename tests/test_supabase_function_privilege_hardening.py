from pathlib import Path


MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "migrations"
    / "0038_supabase_function_privilege_hardening.sql"
)


def test_trigger_functions_pin_search_path_and_qualify_relations():
    sql = MIGRATION.read_text(encoding="utf-8")

    assert "CREATE OR REPLACE FUNCTION public.enforce_single_active_branch_assignment()" in sql
    assert "CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()" in sql
    assert sql.count("SET search_path = ''") == 2
    assert "FROM public.organization_members" in sql
    assert "FROM public.organizational_assignments existing" in sql
    assert "FROM public.organization_member_profiles p" in sql


def test_security_definer_trigger_entry_points_are_not_public_rpc_functions():
    sql = MIGRATION.read_text(encoding="utf-8")

    for function_name in (
        "insightflow_cleanup_deleted_auth_user",
        "insightflow_cleanup_orphaned_branch_organization",
        "rls_auto_enable",
    ):
        statement = (
            f"REVOKE ALL ON FUNCTION public.{function_name}()"
            "\n    FROM PUBLIC, anon, authenticated, service_role;"
        )
        assert statement in sql


def test_auth_cleanup_retains_only_its_explicit_auth_service_grant():
    sql = MIGRATION.read_text(encoding="utf-8")

    assert (
        "GRANT EXECUTE ON FUNCTION public.insightflow_cleanup_deleted_auth_user()"
        "\n    TO supabase_auth_admin;"
    ) in sql


def test_migration_does_not_recreate_or_disable_existing_triggers():
    sql = MIGRATION.read_text(encoding="utf-8").upper()

    assert "CREATE TRIGGER" not in sql
    assert "DROP TRIGGER" not in sql
    assert "CREATE EVENT TRIGGER" not in sql
    assert "DROP EVENT TRIGGER" not in sql


def test_existing_branch_and_employee_integrity_guards_remain_in_place():
    sql = MIGRATION.read_text(encoding="utf-8")

    assert "A person can have active assignments in only one branch." in sql
    assert "pg_catalog.pg_advisory_xact_lock" in sql
    assert "duplicate employee ID proof" in sql
    assert "organization_member_profiles_unique_id_proof" in sql


def test_production_migration_runner_verifies_live_function_privileges():
    runner = (
        Path(__file__).resolve().parents[1]
        / "tools"
        / "run_authz_migrations.py"
    ).read_text(encoding="utf-8")

    assert "def verify_supabase_function_security(engine)" in runner
    assert "has_function_privilege('anon'" in runner
    assert "has_function_privilege('authenticated'" in runner
    assert "has_function_privilege('service_role'" in runner
    assert "has_function_privilege('supabase_auth_admin'" in runner
    assert "verify_supabase_function_security(engine)" in runner
