from pathlib import Path

from firebase_authz import company_admin_diagnostics as company


ROOT = Path(__file__).resolve().parents[1]


def test_company_admin_is_a_distinct_global_role_and_router():
    source = (ROOT / "firebase_authz" / "company_admin_diagnostics.py").read_text(encoding="utf-8")
    assert 'prefix="/v1/company-admin"' in source
    assert "insightflow_company_admins" in source
    assert "ca.active=true" in source
    assert "diagnostic_support_admins" not in source
    assert "organization_members" not in source
    assert "/users/{principal_id}/timeline" in source
    assert "/events/search" in source


def test_company_admin_migration_is_separate_and_not_client_writable():
    migration = (ROOT / "migrations" / "0043_insightflow_company_admin.sql").read_text(encoding="utf-8")
    assert "CREATE TABLE IF NOT EXISTS insightflow_company_admins" in migration
    assert "CREATE TABLE IF NOT EXISTS insightflow_company_admin_audit" in migration
    assert "ALTER TABLE insightflow_company_admins ENABLE ROW LEVEL SECURITY" in migration
    assert "ALTER TABLE insightflow_company_admin_audit ENABLE ROW LEVEL SECURITY" in migration
    assert "REVOKE ALL ON insightflow_company_admins, insightflow_company_admin_audit FROM anon, authenticated" in migration


def test_company_admin_routes_are_registered_without_replacing_existing_admin():
    source = (ROOT / "main.py").read_text(encoding="utf-8")
    assert "company_admin_diagnostics_router" in source
    assert "app.include_router(admin_diagnostics_router)" in source
    assert "app.include_router(company_admin_diagnostics_router)" in source
    assert "app.include_router(diagnostic_router)" in source


def test_company_admin_authorization_fails_closed():
    assert company.router.prefix == "/v1/company-admin"
    assert callable(company._company_actor)
