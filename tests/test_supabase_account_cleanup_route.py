from __future__ import annotations

from firebase_authz import routes
from firebase_authz.service import AuthzError


def test_supabase_account_cleanup_revokes_access_before_deleting_auth_user(monkeypatch):
    calls: list[tuple[str, str]] = []
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        routes,
        "verify_id_token",
        lambda token: {"uid": "user-123", "email_verified": True, "email": "user@example.com"},
    )
    monkeypatch.setattr(routes, "require_email_verified", lambda claims: claims)

    def cleanup(claims, uid):
        assert claims["uid"] == uid
        calls.append(("cleanup", uid))
        return {"revoked_workspaces": ["org-1"]}

    monkeypatch.setattr(
        "firebase_authz.supabase_provider.cleanup_account",
        cleanup,
    )
    monkeypatch.setattr(
        "firebase_authz.supabase_admin.delete_user",
        lambda uid: calls.append(("delete", uid)),
    )

    result = routes.account_cleanup(
        routes.AccountCleanupRequest(uid="user-123"),
        authorization="Bearer test-access-token",
    )

    assert result == {"deleted": True, "revoked_workspaces": ["org-1"]}
    assert calls == [("cleanup", "user-123"), ("delete", "user-123")]


def test_supabase_account_cleanup_never_deletes_another_identity(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        routes,
        "verify_id_token",
        lambda token: {"uid": "user-123", "email_verified": True},
    )
    monkeypatch.setattr(routes, "require_email_verified", lambda claims: claims)
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.cleanup_account",
        lambda claims, uid: (_ for _ in ()).throw(
            AuthzError("Account cleanup identity mismatch.")
        ),
    )
    deleted: list[str] = []
    monkeypatch.setattr(
        "firebase_authz.supabase_admin.delete_user",
        lambda uid: deleted.append(uid),
    )

    from fastapi import HTTPException

    try:
        routes.account_cleanup(
            routes.AccountCleanupRequest(uid="someone-else"),
            authorization="Bearer test-access-token",
        )
    except HTTPException as exc:
        assert exc.status_code == 403
    else:
        raise AssertionError("Expected mismatched identity to be rejected")

    assert deleted == []
