from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PASSWORD = ROOT / "flutter_detail_source/lib/features/auth/employee_invitation_password_setup_screen.dart"
ONBOARDING = ROOT / "flutter_detail_source/lib/features/auth/organization_onboarding_screen.dart"
AUTH = ROOT / "flutter_detail_source/lib/core/auth/supabase_auth_service.dart"


def test_password_setup_has_bounded_auth_backend_and_acceptance_requests():
    source = PASSWORD.read_text(encoding="utf-8")
    assert "InsightFlowSupabaseAuthService.signUp(" in source
    assert "emailRedirectTo: redirect" in source
    assert "'token': invitationToken" in source
    assert ".timeout(const Duration(seconds: 10))" in source
    assert "/v1/authz/invitations/password-setup-complete" in source
    assert "Uri.base.queryParameters['token']" in source
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


def test_invitation_acceptance_backend_does_not_use_nullable_sql_parameter_for_org_constraint():
    provider = (ROOT / "firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    assert "AND (:org IS NULL OR organization_id=:org)" not in provider
    assert "if workspace_id:" in provider
    assert "organization_id=:org" in provider


def test_invitation_link_is_validated_before_signup_and_keeps_token_in_redirect():
    gate = (ROOT / "flutter_detail_source/lib/features/auth/auth_gate.dart").read_text(encoding="utf-8")
    service = AUTH.read_text(encoding="utf-8")
    provider = (ROOT / "firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    routes = (ROOT / "firebase_authz/routes.py").read_text(encoding="utf-8")
    assert "Uri.base.queryParameters['token']" in gate
    assert "/v1/authz/invitations/preview" in gate
    assert "String? emailRedirectTo" in service
    assert "def get_invitation_by_token(token: str)" in provider
    assert '@router.get("/invitations/preview")' in routes
    assert "invite_user_by_email(" not in provider[provider.index("def create_invitation("):provider.index("def get_invitation_by_token(")]


def test_invitation_signup_offers_existing_account_signin_path():
    source = PASSWORD.read_text(encoding="utf-8")
    assert "Already have an account? Sign in first" in source
    assert "const SignInScreen()" in source
