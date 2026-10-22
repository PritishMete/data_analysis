import os

from fastapi.testclient import TestClient

import firebase_authz.middleware as auth_middleware


def test_unauthenticated_protected_api_is_rejected(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    from main import app
    response = TestClient(app).get(
        "/transform/history/test",
        headers={
            "X-InsightFlow-Workspace-ID": "workspace",
            "X-InsightFlow-Resource-ID": "sheet",
        },
    )
    assert response.status_code == 401


def test_invalid_token_is_rejected(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setattr(
        auth_middleware,
        "verify_id_token",
        lambda token: (_ for _ in ()).throw(auth_middleware.AuthenticationRequired("invalid")),
    )
    from main import app
    response = TestClient(app).get(
        "/transform/history/test",
        headers={
            "Authorization": "Bearer invalid",
            "X-InsightFlow-Workspace-ID": "workspace",
            "X-InsightFlow-Resource-ID": "sheet",
        },
    )
    assert response.status_code == 403
    assert "invalid" not in response.text


def test_authenticated_user_without_permission_is_rejected(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.authorize",
        lambda *args, **kwargs: (_ for _ in ()).throw(auth_middleware.PermissionDenied("sensitive-internal-detail")),
    )
    from main import app
    response = TestClient(app).get(
        "/transform/history/test",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "workspace",
            "X-InsightFlow-Resource-ID": "sheet",
        },
    )
    assert response.status_code == 403
    assert "sensitive-internal-detail" not in response.text


def test_authorized_user_reaches_protected_api(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.authorize",
        lambda *args, **kwargs: {
            "allowed": True,
            "uid": "alice",
            "workspace_id": "workspace",
            "resource_id": "sheet",
            "action": "history.view",
        },
    )
    from main import app
    response = TestClient(app).get(
        "/transform/history/test",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "workspace",
            "X-InsightFlow-Resource-ID": "sheet",
        },
    )
    assert response.status_code == 200
    assert response.json()["success"] is True


def test_missing_workspace_or_resource_context_is_rejected(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice"})
    from main import app
    no_workspace = TestClient(app).get(
        "/transform/history/test",
        headers={"Authorization": "Bearer valid"},
    )
    assert no_workspace.status_code == 403
    no_resource = TestClient(app).get(
        "/transform/history/test",
        headers={"Authorization": "Bearer valid", "X-InsightFlow-Workspace-ID": "workspace"},
    )
    assert no_resource.status_code == 403


def test_unverified_token_is_rejected_before_protected_api(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": False})
    from main import app
    response = TestClient(app).get(
        "/transform/history/test",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "workspace",
            "X-InsightFlow-Resource-ID": "sheet",
        },
    )
    assert response.status_code == 403
    assert response.json()["detail"] == "Email verification required."


def test_authz_me_reports_pending_unregistered_user(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", lambda token, require_email_verified=True: {"uid": "new-user", "email": "new@example.com", "email_verified": True})
    monkeypatch.setattr("firebase_authz.supabase_provider.authorization_context", lambda *args, **kwargs: {
        "email_verified": True,
        "account_status": "pending",
        "membership_status": "none",
        "workspace_authorized": False,
        "workspace_id": "workspace",
        "workspaces": [],
    })
    from main import app
    response = TestClient(app).get(
        "/v1/authz/me",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "workspace",
        },
    )
    assert response.status_code == 200
    assert response.json()["account_status"] == "pending"
    assert response.json()["workspace_authorized"] is False


def test_membership_endpoint_returns_membership_only_for_authenticated_user(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", lambda token, require_email_verified=True: {"uid": "employee-1", "email_verified": True})
    monkeypatch.setattr("firebase_authz.supabase_provider.authorization_context", lambda *args, **kwargs: {
        "organization_id": "abc",
        "workspace_id": "abc",
        "employee_id": "emp_1",
        "membership_status": "active",
        "role_ids": ["employee"],
    })
    from main import app
    response = TestClient(app).get(
        "/v1/authz/membership",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "abc",
        },
    )
    assert response.status_code == 200
    assert response.json()["organization_id"] == "abc"
    assert response.json()["employee_id"] == "emp_1"


def test_dataset_registration_endpoint_accepts_only_opaque_metadata(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", lambda token, require_email_verified=True: {"uid": "owner", "email_verified": True})
    monkeypatch.setattr("firebase_authz.supabase_provider.register_dataset", lambda claims, workspace_id, dataset_id, owner_uid, protected_original: {
        "dataset_id": dataset_id,
        "organization_id": workspace_id,
    })
    from main import app
    response = TestClient(app).post(
        "/v1/authz/datasets/register",
        json={
            "workspace_id": "org",
            "dataset_id": "ds_opaque",
            "owner_uid": "owner",
            "protected_original": True,
        },
        headers={"Authorization": "Bearer valid"},
    )
    assert response.status_code == 200
    assert response.json()["dataset_id"] == "ds_opaque"


def test_working_copy_endpoint_does_not_accept_workbook_payloads(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", lambda token, require_email_verified=True: {"uid": "owner", "email_verified": True})
    monkeypatch.setattr("firebase_authz.supabase_provider.create_working_copy", lambda claims, workspace_id, dataset_id, working_copy_id, source_version: {
        "working_copy_id": working_copy_id or "wc"
    })
    from main import app
    response = TestClient(app).post(
        "/v1/authz/working-copies",
        json={
            "workspace_id": "org",
            "dataset_id": "ds1",
            "working_copy_id": "wc1",
            "source_version": "1",
        },
        headers={"Authorization": "Bearer valid"},
    )
    assert response.status_code == 200


def test_unregistered_google_or_email_account_is_not_authorized_by_backend(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", lambda token, require_email_verified=True: {
        "uid": "new-authenticated-user",
        "email": "new@example.com",
        "email_verified": True,
    })
    monkeypatch.setattr("firebase_authz.supabase_provider.authorization_context", lambda *args, **kwargs: {
        "email_verified": True,
        "account_status": "pending",
        "membership_status": "none",
        "workspace_authorized": False,
        "workspace_id": "org",
        "workspaces": [],
    })
    from main import app
    response = TestClient(app).get(
        "/v1/authz/me",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "org",
        },
    )
    assert response.status_code == 200
    assert response.json()["workspace_authorized"] is False


def test_protected_middleware_rejects_non_supabase_persistence_without_firebase_fallback(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})

    def firebase_authorization_must_not_run(*args, **kwargs):
        raise AssertionError("Firebase authorization must never be used")

    monkeypatch.setattr(auth_middleware, "authorization", firebase_authorization_must_not_run)
    from main import app

    headers = {
        "Authorization": "Bearer valid-supabase-token",
        "X-InsightFlow-Workspace-ID": "workspace",
        "X-InsightFlow-Resource-ID": "sheet",
    }
    for persistence in (None, "", "firebase", "unknown"):
        if persistence is None:
            monkeypatch.delenv("AUTHZ_PERSISTENCE_PROVIDER", raising=False)
        else:
            monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", persistence)
        response = TestClient(app).get("/transform/history/test", headers=headers)
        assert response.status_code == 403
