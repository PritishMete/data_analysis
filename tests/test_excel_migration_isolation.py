from tools.run_authz_migrations import migration_files


def test_excel_handoff_migrations_are_not_applied_by_authz_startup_runner():
    names = {path.name for path in migration_files()}
    assert "0037_excel_auth_handoff.sql" not in names
    assert "0038_excel_auth_pairing.sql" not in names
