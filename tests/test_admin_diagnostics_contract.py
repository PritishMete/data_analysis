from pathlib import Path
import pytest

from firebase_authz import admin_diagnostics as diagnostics
from firebase_authz.admin_diagnostics import _csv_safe, _scope, _safe_payload


ROOT = Path(__file__).resolve().parents[1]


def test_admin_router_is_independent_and_server_authorized():
    source = (ROOT / "firebase_authz" / "admin_diagnostics.py").read_text(encoding="utf-8")
    assert 'prefix="/v1/admin"' in source
    assert "verify_supabase_access_token" in source
    assert "organization_owner" in source
    assert "diagnostic_support_admins" in source
    assert "audit_events" in source
    assert "JOIN organization_members target_member" in source
    assert "diagnostic_router = APIRouter(prefix=\"/v1/diagnostics\"" in source
    assert "claim_token_hash" in source
    assert "Diagnostic event rate limit exceeded" in source


def test_diagnostic_migration_is_additive_and_separate_from_audit_events():
    migration = (ROOT / "migrations" / "0042_diagnostic_admin.sql").read_text(encoding="utf-8")
    assert "CREATE TABLE IF NOT EXISTS diagnostic_sessions" in migration
    assert "CREATE TABLE IF NOT EXISTS diagnostic_events" in migration
    assert "ALTER TABLE diagnostic_events ENABLE ROW LEVEL SECURITY" in migration
    assert "REVOKE ALL ON diagnostic_sessions, diagnostic_events" in migration
    assert "diagnostic_session_claim_state" in migration
    assert "claim_token_hash TEXT," in migration
    assert "diagnostic_events_branch_idx" in migration
    assert "organization_id TEXT NOT NULL REFERENCES organizations" in migration


def test_admin_frontend_has_no_main_app_mount():
    frontend = ROOT / "apps" / "admin_portal"
    assert (frontend / "wrangler.toml").exists()
    assert (frontend / "src" / "index.html").exists()
    assert "admin" in (frontend / "README.md").read_text(encoding="utf-8").lower()
    build = (frontend / "build.mjs").read_text(encoding="utf-8")
    assert "INSIGHTFLOW_ADMIN_API" in build
    assert "JSON.stringify(config)" in build
    assert "Production admin build requires" in build


def test_scope_rejects_arbitrary_organization_and_support_branch_expansion():
    owner = {"organization_id": "org-a", "support_active": False}
    with pytest.raises(Exception):
        _scope(owner, "org-b")
    support = {"organization_id": "org-a", "support_active": True, "support_org": "org-a", "support_branch": "branch-1"}
    assert _scope(support) == ("org-a", "branch-1")
    with pytest.raises(Exception):
        _scope(support, branch_id="branch-2")


def test_session_and_csv_controls_are_safe():
    source = (ROOT / "firebase_authz" / "admin_diagnostics.py").read_text(encoding="utf-8")
    assert "secrets.token_urlsafe(48)" in source
    assert "hashlib.sha256" in source
    assert _csv_safe("=SUM(A1:A2)").startswith("'")
    assert _csv_safe("@cmd") == "'@cmd"
    assert _csv_safe("normal") == "normal"
    frontend = (ROOT / "apps" / "admin_portal" / "src" / "app.js").read_text(encoding="utf-8")
    assert "sessionStorage" not in frontend
    assert "logger" not in source.lower()
    assert "print(" not in source


def test_diagnostic_payload_allowlist_rejects_authentication_material():
    assert _safe_payload({"stage": "oauth_callback", "unknown": "dropped"}) == {"stage": "oauth_callback"}
    with pytest.raises(Exception):
        _safe_payload({"access_token": "Bearer eyJsecret"})
    with pytest.raises(Exception):
        _safe_payload({"metadata": {"authorization": "Bearer eyJsecret"}})


def test_anonymous_rate_limiter_has_hard_cap_and_expiry_cleanup():
    diagnostics._anonymous_rate_buckets.clear()
    for index in range(diagnostics.ANONYMOUS_RATE_MAX_BUCKETS):
        diagnostics._anonymous_rate_limit(f"client-{index}", 1000.0)
    assert len(diagnostics._anonymous_rate_buckets) == diagnostics.ANONYMOUS_RATE_MAX_BUCKETS
    with pytest.raises(Exception):
        diagnostics._anonymous_rate_limit("overflow", 1000.0)
    diagnostics._anonymous_rate_limit("new-client", 1061.0)
    assert len(diagnostics._anonymous_rate_buckets) <= diagnostics.ANONYMOUS_RATE_MAX_BUCKETS


def test_anonymous_rate_limiter_handles_missing_client_bucket():
    diagnostics._anonymous_rate_buckets.clear()
    diagnostics._anonymous_rate_limit("unknown", 2000.0)
    assert "unknown" in diagnostics._anonymous_rate_buckets



def test_company_wide_admin_uses_distinct_server_authorization():
    from firebase_authz import company_admin_diagnostics as company

    source = (ROOT / "firebase_authz" / "company_admin_diagnostics.py").read_text(encoding="utf-8")
    migration = (ROOT / "migrations" / "0043_insightflow_company_admin.sql").read_text(encoding="utf-8")
    assert company.router.prefix == "/v1/company-admin"
    assert "insightflow_company_admins" in source
    assert "ca.active=true" in source
    assert "diagnostic_support_admins" not in source
    assert "organization_members" not in source
    assert "/users/{principal_id}/timeline" in source
    assert "/events/search" in source
    assert "ALTER TABLE insightflow_company_admins ENABLE ROW LEVEL SECURITY" in migration
    assert "ALTER TABLE insightflow_company_admin_audit ENABLE ROW LEVEL SECURITY" in migration
    assert "REVOKE ALL ON insightflow_company_admins, insightflow_company_admin_audit FROM anon, authenticated" in migration


def test_customer_client_telemetry_is_persistent_and_privacy_filtered():
    telemetry = (ROOT / "apps" / "flutter_app" / "lib" / "core" / "services" / "diagnostic_telemetry_service.dart").read_text(encoding="utf-8")
    excel = (ROOT / "apps" / "flutter_app" / "lib" / "core" / "auth" / "excel_auth_diagnostics.dart").read_text(encoding="utf-8")
    auth = (ROOT / "apps" / "flutter_app" / "lib" / "core" / "auth" / "supabase_auth_service.dart").read_text(encoding="utf-8")
    managed = (ROOT / "apps" / "flutter_app" / "lib" / "features" / "auth" / "managed_dataset_access_workspace.dart").read_text(encoding="utf-8")
    assert "/v1/diagnostics/sessions" in telemetry
    assert "/v1/diagnostics/events" in telemetry
    assert "claim_secret" in telemetry
    assert "excel_auth_popup" in excel
    assert "google_oauth" in auth
    assert "managed_branch_data" in managed
    assert "response.body" not in telemetry
    assert "workbook" not in telemetry.lower()
    assert "refresh_token" not in telemetry.lower()
