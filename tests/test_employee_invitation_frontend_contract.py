from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PASSWORD = ROOT / "flutter_detail_source/lib/features/auth/employee_invitation_password_setup_screen.dart"
ONBOARDING = ROOT / "flutter_detail_source/lib/features/auth/organization_onboarding_screen.dart"
AUTH = ROOT / "flutter_detail_source/lib/core/auth/supabase_auth_service.dart"


def test_password_setup_has_bounded_auth_backend_and_acceptance_requests():
    source = PASSWORD.read_text(encoding="utf-8")
    assert "setPassword(\n        password,\n        timeout: const Duration(seconds: 10)," in source
    assert ".timeout(const Duration(seconds: 10))" in source
    assert "/v1/authz/invitations/password-setup-complete" in source
    assert "/v1/authz/invitations/accept" in source
    assert "await widget.onCompleted().timeout(const Duration(seconds: 10));" in source


def test_password_setup_clears_loading_state_on_all_paths():
    source = PASSWORD.read_text(encoding="utf-8")
    assert "} finally {\n      if (mounted) setState(() => _busy = false);\n    }" in source
    assert "Please retry" in source


def test_session_refresh_is_bounded():
    source = AUTH.read_text(encoding="utf-8")
    assert "refreshSession()" in source
    assert ".timeout(timeout)" in source
    assert "static Future<Session?> ensureSession" in source


def test_invitation_onboarding_uses_authoritative_org_name_only():
    for path in (PASSWORD, ONBOARDING):
        source = path.read_text(encoding="utf-8")
        assert "organization_id']?.toString() ??" not in source
        assert "organization_name" in source
        assert "You’re invited to join" in source
        assert "Complete your employee onboarding" in source


def test_pending_invitation_backend_exposes_org_name_without_user_facing_id_fallback():
    provider = (ROOT / "firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    assert "o.name AS organization_name" in provider
    assert "JOIN organizations o ON o.organization_id=i.organization_id" in provider
