from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_admin_router_is_independent_and_server_authorized():
    source = (ROOT / "firebase_authz" / "admin_diagnostics.py").read_text(encoding="utf-8")
    assert 'prefix="/v1/admin"' in source
    assert "verify_supabase_access_token" in source
    assert "organization_owner" in source
    assert "diagnostic_support_admins" in source
    assert "audit_events" in source


def test_diagnostic_migration_is_additive_and_separate_from_audit_events():
    migration = (ROOT / "migrations" / "0042_diagnostic_admin.sql").read_text(encoding="utf-8")
    assert "CREATE TABLE IF NOT EXISTS diagnostic_sessions" in migration
    assert "CREATE TABLE IF NOT EXISTS diagnostic_events" in migration
    assert "ALTER TABLE diagnostic_events ENABLE ROW LEVEL SECURITY" in migration
    assert "REVOKE ALL ON diagnostic_sessions, diagnostic_events" in migration


def test_admin_frontend_has_no_main_app_mount():
    frontend = ROOT / "apps" / "admin_portal"
    assert (frontend / "wrangler.toml").exists()
    assert (frontend / "src" / "index.html").exists()
    assert "admin" in (frontend / "README.md").read_text(encoding="utf-8").lower()
