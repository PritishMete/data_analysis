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
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice"})
    monkeypatch.setattr(
        auth_middleware,
        "authorization",
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
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice"})
    monkeypatch.setattr(
        auth_middleware,
        "authorization",
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
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "new-user", "email": "new@example.com", "email_verified": True})
    monkeypatch.setattr(routes, "authentication_context", lambda *args, **kwargs: {
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
