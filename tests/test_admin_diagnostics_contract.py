from pathlib import Path
import pytest

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
