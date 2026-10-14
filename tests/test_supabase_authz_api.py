import os

from fastapi.testclient import TestClient

import firebase_authz.middleware as auth_middleware
from firebase_authz import supabase_provider


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
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})
    monkeypatch.setattr(
        supabase_provider,
        "authorize",
        lambda *args, **kwargs: (_ for _ in ()).throw(supabase_provider.AuthzError("sensitive-internal-detail")),
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
    monkeypatch.setattr(auth_middleware, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})
    monkeypatch.setattr(
        supabase_provider,
        "authorize",
        lambda *args, **kwargs: {
            "authorized": True,
            "principal_id": "alice",
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
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda *args, **kwargs: {
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
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "employee-1", "email_verified": True})
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda *args, **kwargs: {
        "organization_id": "abc",
        "workspace_id": "abc",
        "employee_id": "emp_1",
        "membership_status": "active",
        "workspaces": [{"workspace_id": "abc", "role_ids": ["employee"]}],
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
    monkeypatch.setattr(supabase_provider, "register_dataset", lambda claims, workspace_id, dataset_id, owner_uid, protected: {
        "dataset_id": dataset_id,
        "organization_id": workspace_id,
    })
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "owner", "email_verified": True})
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
    import dataset_storage.service as dataset_service

    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "owner", "sub": "owner", "email_verified": True})
    calls = {}

    def create_snapshot(claims, workspace_id, dataset_id, *, source_version_id=None, assigned_to_principal_id=None, db_session=None):
        calls.update({
            "claims": claims,
            "workspace_id": workspace_id,
            "dataset_id": dataset_id,
            "source_version_id": source_version_id,
        })
        return {
            "working_copy_id": "wc-server-generated",
            "structured_dataset_id": "copy-dataset",
            "structured_version_id": "1",
            "source_dataset_id": dataset_id,
        }

    monkeypatch.setattr(dataset_service, "_create_managed_working_copy_from_claims", create_snapshot)
    from main import app
    response = TestClient(app).post(
        "/v1/authz/working-copies",
        json={
            "workspace_id": "org",
            "dataset_id": "ds1",
            "working_copy_id": "client-chosen-id",
            "source_version": "1",
            "workbook": {"rows": [{"secret": "must-not-be-accepted-as-content"}]},
        },
        headers={"Authorization": "Bearer valid"},
    )
    assert response.status_code == 200
    assert response.json()["working_copy_id"] == "wc-server-generated"
    assert calls["dataset_id"] == "ds1"
    assert calls["source_version_id"] == "1"
    assert calls["workspace_id"] == "org"


def test_unregistered_google_or_email_account_is_not_authorized_by_backend(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {
        "uid": "new-authenticated-user",
        "email": "new@example.com",
        "email_verified": True,
    })
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda *args, **kwargs: {
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
