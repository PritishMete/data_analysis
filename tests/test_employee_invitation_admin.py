import pytest
from pydantic import ValidationError

from firebase_authz.routes import InvitationAcceptRequest
from firebase_authz.supabase_admin import invite_user_by_email


class _FakeUser:
    id = "auth-user-123"
    email_confirmed_at = None


class _FakeAdmin:
    def __init__(self):
        self.calls = []

    def invite_user_by_email(self, email, *, options):
        self.calls.append((email, options))
        return type("Response", (), {"user": _FakeUser()})()


class _FakeAuth:
    def __init__(self):
        self.admin = _FakeAdmin()


class _FakeClient:
    def __init__(self):
        self.auth = _FakeAuth()


def test_supabase_admin_invite_uses_server_redirect_and_returns_user(monkeypatch):
    fake = _FakeClient()
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SECRET_KEY", "server-only-test-secret")
    monkeypatch.setattr(
        "firebase_authz.supabase_admin.admin_client",
        lambda: fake,
    )

    result = invite_user_by_email(
        "employee@example.com",
        "https://pritishmete.github.io/data_analysis/employee-invite",
    )

    assert result == {"user_id": "auth-user-123", "email_confirmed": False}
    assert fake.auth.admin.calls == [
        (
            "employee@example.com",
            {"redirect_to": "https://pritishmete.github.io/data_analysis/employee-invite"},
        )
    ]


def test_invitation_acceptance_request_does_not_require_client_workspace():
    request = InvitationAcceptRequest(invitation_id="inv-123")
    assert request.invitation_id == "inv-123"
    assert request.workspace_id is None


def test_invitation_acceptance_request_rejects_extra_client_context():
    with pytest.raises(ValidationError):
        InvitationAcceptRequest(
            invitation_id="inv-123",
            workspace_id="org-client-supplied",
            branch_id="forged-branch",
            section_id="forged-section",
            role_id="forged-role",
        )


def test_supabase_admin_prefers_new_secret_key(monkeypatch):
    from firebase_authz.supabase_admin import _credential_candidates, _supabase_secret

    monkeypatch.setenv("SUPABASE_SECRET_KEY", "sb_secret_preferred")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "legacy-service-role")
    assert _credential_candidates() == [
        ("SUPABASE_SECRET_KEY", "sb_secret_preferred"),
        ("SUPABASE_SERVICE_ROLE_KEY", "legacy-service-role"),
    ]
    assert _supabase_secret() == "sb_secret_preferred"


def test_supabase_admin_falls_back_to_service_role_only_on_auth_rejection(monkeypatch):
    from firebase_authz.supabase_admin import invite_user_by_email

    calls = []

    class _AuthFailure(Exception):
        status_code = 401

    class _SecondUser:
        id = "legacy-user-456"
        email_confirmed_at = None

    class _SecondAdmin:
        def invite_user_by_email(self, email, *, options):
            calls.append("service_role")
            return type("Response", (), {"user": _SecondUser()})()

    class _SecondAuth:
        admin = _SecondAdmin()

    class _SecondClient:
        auth = _SecondAuth()

    def fake_client(source, credential):
        calls.append(source)
        if source == "SUPABASE_SECRET_KEY":
            raise _AuthFailure("invalid admin credential")
        return _SecondClient()

    monkeypatch.setenv("SUPABASE_SECRET_KEY", "sb_secret_invalid")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "legacy-valid")
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setattr("firebase_authz.supabase_admin._credential_client", fake_client)

    result = invite_user_by_email("employee@example.com", "https://example.com/invite")
    assert result == {"user_id": "legacy-user-456", "email_confirmed": False}
    assert calls == ["SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY", "service_role"]


def test_supabase_admin_does_not_fallback_for_non_auth_admin_errors(monkeypatch):
    from firebase_authz.supabase_admin import invite_user_by_email

    calls = []

    class _ProviderFailure(Exception):
        status_code = 500

    def fake_client(source, credential):
        calls.append(source)
        raise _ProviderFailure("mail provider failure")

    monkeypatch.setenv("SUPABASE_SECRET_KEY", "sb_secret_configured")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "legacy-configured")
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setattr("firebase_authz.supabase_admin._credential_client", fake_client)

    with pytest.raises(_ProviderFailure):
        invite_user_by_email("employee@example.com", "https://example.com/invite")
    assert calls == ["SUPABASE_SECRET_KEY"]


def test_supabase_admin_missing_credentials_fails_as_configuration_error(monkeypatch):
    from firebase_authz.supabase_admin import SupabaseAdminConfigurationError, admin_client

    monkeypatch.delenv("SUPABASE_SECRET_KEY", raising=False)
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")

    with pytest.raises(SupabaseAdminConfigurationError):
        admin_client()


def test_supabase_admin_diagnostic_logging_never_logs_credentials(monkeypatch, caplog):
    from firebase_authz.supabase_admin import invite_user_by_email

    class _AuthFailure(Exception):
        status_code = 401

    secret = "sb_secret_DO_NOT_LOG_THIS"
    monkeypatch.setenv("SUPABASE_SECRET_KEY", secret)
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")

    def fake_client(source, credential):
        raise _AuthFailure(f"Authorization: Bearer {secret}")

    monkeypatch.setattr("firebase_authz.supabase_admin._credential_client", fake_client)
    with caplog.at_level("WARNING"):
        with pytest.raises(_AuthFailure):
            invite_user_by_email("employee@example.com", "https://example.com/invite")

    assert secret not in caplog.text
    assert "REDACTED" in caplog.text
