from pathlib import Path

from firebase_authz import company_admin_diagnostics as company


ROOT = Path(__file__).resolve().parents[1]


def test_company_admin_is_a_distinct_global_role_and_router():
    source = (ROOT / "firebase_authz" / "company_admin_diagnostics.py").read_text(encoding="utf-8")
    assert 'prefix="/v1/company-admin"' in source
    assert "insightflow_company_admins" in source
    assert "ca.active=true" in source
    assert "diagnostic_support_admins" not in source
    assert "organization_members" not in source.split("def _audit", 1)[0]
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



def test_global_admin_and_diagnostic_routes_bypass_tenant_workspace_policy():
    from firebase_authz.middleware import route_policy

    for path in (
        "/v1/admin/overview",
        "/v1/company-admin/overview",
        "/v1/diagnostics/sessions",
        "/v1/diagnostics/sessions/claim",
        "/v1/diagnostics/events",
    ):
        assert route_policy(path) is None


def test_global_admin_includes_companies_users_and_backend_request_logs():
    company_source = (ROOT / "firebase_authz" / "company_admin_diagnostics.py").read_text(encoding="utf-8")
    main_source = (ROOT / "main.py").read_text(encoding="utf-8")
    migration = (ROOT / "migrations" / "0044_platform_backend_events.sql").read_text(encoding="utf-8")
    portal = (ROOT / "apps" / "admin_portal" / "src" / "app.js").read_text(encoding="utf-8")
    assert '@router.get("/companies")' in company_source
    assert "FROM organization_members" in company_source
    assert "LEFT JOIN member_roles" in company_source
    assert "LEFT JOIN roles" in company_source
    assert "membership_statuses" in company_source
    assert '@router.get("/backend-requests")' in company_source
    assert "BackendRequestObservabilityMiddleware" in main_source
    assert "CREATE TABLE IF NOT EXISTS platform_backend_events" in migration
    stack_migration = (ROOT / "migrations" / "0045_backend_error_stack.sql").read_text(encoding="utf-8")
    assert "ADD COLUMN IF NOT EXISTS error_stack TEXT" in stack_migration
    assert "error_stack" in company_source
    assert "backend-requests:Backend request logs" in portal


def test_backend_observability_redacts_authentication_and_personal_values():
    from firebase_authz.observability import sanitize_error_message

    value = sanitize_error_message(
        "Bearer abc.def token eyJabc.def.ghi user test@example.com phone +1 202-555-0100"
    )
    assert "abc.def" not in value
    assert "test@example.com" not in value
    assert "+1 202-555-0100" not in value


def test_backend_observability_covers_all_api_route_families_without_health_noise():
    from firebase_authz.observability import should_observe_path

    for path in ("/analyze", "/transform/undo", "/powerbi/dashboard", "/v2/detail-analysis", "/v1/company-admin/overview"):
        assert should_observe_path(path) is True
    for path in ("/", "/health", "/ping", "/powerbi/ping", "/openapi.json", "/docs"):
        assert should_observe_path(path) is False
