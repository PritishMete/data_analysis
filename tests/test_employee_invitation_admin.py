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
