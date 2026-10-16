"""Regression tests for the mounted, Supabase-only /v1/authz/me contract.

These tests deliberately exercise the FastAPI application object (rather than
only importing the route module) so a deployment that omits include_router()
fails before it can publish a broken backend.
"""
from fastapi.testclient import TestClient

from firebase_authz import routes as authz_routes
from firebase_authz.auth import AuthenticationRequired


def _client(monkeypatch):
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    from main import app

    return TestClient(app)


def test_authz_me_is_mounted_and_rejects_missing_bearer_token(monkeypatch):
    client = _client(monkeypatch)

    response = client.get("/v1/authz/me")

    assert response.status_code == 401
    assert "Supabase authentication required" in response.text


def test_authz_me_rejects_invalid_supabase_session(monkeypatch):
    client = _client(monkeypatch)

    def reject_token(_token):
        raise AuthenticationRequired("Supabase authentication failed.")

    monkeypatch.setattr(authz_routes, "verify_id_token", reject_token)
    response = client.get(
        "/v1/authz/me",
        headers={"Authorization": "Bearer invalid-test-token"},
    )

    assert response.status_code == 401
    assert "Supabase authentication failed" in response.text


def test_confirmed_supabase_identity_receives_authoritative_membership(monkeypatch):
    client = _client(monkeypatch)
    claims = {
        "uid": "supabase-user-test",
        "sub": "supabase-user-test",
        "email": "member@example.test",
        "email_verified": True,
    }
    context = {
        "membership_status": "active",
        "workspace_authorized": True,
        "authorization_state": "active_identity",
        "principal_id": "principal-test",
        "organization_id": "org-test",
        "organization_name": "Test Organization",
        "workspace_id": "workspace-test",
        "employee_id": "EMP001",
        "role_ids": ["branch_head"],
        "permissions": [],
        "profile_complete": True,
        "workspaces": [
            {
                "workspace_id": "workspace-test",
                "organization_id": "org-test",
                "employee_id": "EMP001",
                "membership_status": "active",
                "profile_complete": True,
                "role_ids": ["branch_head"],
            }
        ],
    }
    monkeypatch.setattr(authz_routes, "verify_id_token", lambda _token: claims)
    from firebase_authz import supabase_provider

    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda verified_claims, workspace_id=None: context,
    )

    response = client.get(
        "/v1/authz/me",
        headers={"Authorization": "Bearer verified-test-token"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["uid"] == "supabase-user-test"
    assert body["organization_id"] == "org-test"
    assert body["organization_name"] == "Test Organization"
    assert body["workspace_id"] == "workspace-test"
    assert body["membership_status"] == "active"
    assert body["role_ids"] == ["branch_head"]


def test_confirmed_supabase_identity_without_membership_is_not_service_failure(
    monkeypatch,
):
    client = _client(monkeypatch)
    claims = {
        "uid": "supabase-user-without-membership",
        "sub": "supabase-user-without-membership",
        "email": "new-user@example.test",
        "email_verified": True,
    }
    no_membership = {
        "membership_status": "none",
        "workspace_authorized": False,
        "authorization_state": "no_organization_access",
        "principal_id": None,
        "organization_id": None,
        "workspace_id": None,
        "employee_id": None,
        "role_ids": [],
        "permissions": [],
        "workspaces": [],
    }
    monkeypatch.setattr(authz_routes, "verify_id_token", lambda _token: claims)
    from firebase_authz import supabase_provider

    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda verified_claims, workspace_id=None: no_membership,
    )

    response = client.get(
        "/v1/authz/me",
        headers={"Authorization": "Bearer verified-test-token"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["membership_status"] == "none"
    assert body["organization_id"] is None
    assert body["workspace_id"] is None
    assert body["role_ids"] == []
    assert body["workspaces"] == []
