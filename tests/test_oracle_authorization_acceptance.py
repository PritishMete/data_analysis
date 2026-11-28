"""Synthetic acceptance matrix for the backend authorization cutover.

The app is deliberately disposable: FastAPI, the production middleware, and
route-policy functions are real; token verification and authorization storage
are replaced only at their external boundary so this suite never needs a
second database or a live Supabase project.
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import firebase_authz.middleware as auth_middleware


WORKSPACE = "ws_acceptance"
RESOURCE = "resource_acceptance"
DATASET = "ds_acceptance"


@pytest.fixture()
def acceptance_client(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        auth_middleware,
        "verify_supabase_access_token",
        lambda token, require_email_verified=True: ({
            "uid": "acceptance-user",
            "email_verified": True,
        } if token != "invalid" else (_ for _ in ()).throw(auth_middleware.AuthenticationRequired("invalid"))),
    )

    def authorize(claims, workspace_id, action, resource_id=None):
        if workspace_id != WORKSPACE or resource_id in {"wrong-resource", "wrong-dataset"}:
            raise auth_middleware.PermissionDenied("isolated mismatch")
        return {"allowed": True, "action": action, "resource_id": resource_id}

    monkeypatch.setattr("firebase_authz.supabase_provider.authorize", authorize)

    app = FastAPI()
    app.add_middleware(auth_middleware.FirebaseAuthorizationMiddleware)

    @app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
    async def disposable_endpoint(path: str):
        return {"reached": True, "path": path}

    return TestClient(app)


PROTECTED_ROUTES = [
    ("/v1/chat/plan", "POST"),
    ("/v1/assistant/meta", "GET"),
    ("/conversation/state", "GET"),
    ("/v1/system/diagnostics", "GET"),
    ("/powerbi/dashboard", "POST"),
    (f"/v1/managed-datasets/{DATASET}", "GET"),
]


@pytest.mark.parametrize("path, method", PROTECTED_ROUTES)
def test_protected_surface_requires_a_bearer_token(acceptance_client, path, method):
    response = acceptance_client.request(
        method, path, headers={"X-InsightFlow-Workspace-ID": WORKSPACE}
    )
    assert response.status_code == 401


@pytest.mark.parametrize("authorization", ["Bearer", "Bearer ", "Basic token", "Bearer invalid"])
def test_missing_or_invalid_bearer_is_rejected(acceptance_client, authorization):
    response = acceptance_client.get(
        "/v1/chat/plan",
        headers={
            "Authorization": authorization,
            "X-InsightFlow-Workspace-ID": WORKSPACE,
            "X-InsightFlow-Resource-ID": RESOURCE,
        },
    )
    assert response.status_code in {401, 403}


def test_missing_workspace_and_resource_context_are_rejected(acceptance_client):
    no_workspace = acceptance_client.get("/v1/assistant/meta")
    assert no_workspace.status_code == 401

    no_resource = acceptance_client.post(
        "/v1/chat/plan",
        headers={"Authorization": "Bearer valid", "X-InsightFlow-Workspace-ID": WORKSPACE},
    )
    assert no_resource.status_code == 403


@pytest.mark.parametrize(
    "headers",
    [
        {"X-InsightFlow-Workspace-ID": "wrong-workspace", "X-InsightFlow-Resource-ID": RESOURCE},
        {"X-InsightFlow-Workspace-ID": WORKSPACE, "X-InsightFlow-Resource-ID": "wrong-resource"},
    ],
)
def test_workspace_and_resource_mismatches_are_denied(acceptance_client, headers):
    headers["Authorization"] = "Bearer valid"
    response = acceptance_client.get("/conversation/state", headers=headers)
    assert response.status_code == 403


def test_unauthorized_multipart_upload_is_denied_before_route(acceptance_client, monkeypatch):
    def deny_upload(*args, **kwargs):
        if args[2] == "dataset.upload":
            raise auth_middleware.PermissionDenied("upload not granted")
        return {"allowed": True}

    monkeypatch.setattr("firebase_authz.supabase_provider.authorize", deny_upload)
    response = acceptance_client.post(
        "/powerbi/customer-clean",
        files={"file": ("input.csv", b"id,value\n1,2\n", "text/csv")},
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": WORKSPACE,
            "X-InsightFlow-Resource-ID": RESOURCE,
        },
    )
    assert response.status_code == 403


def test_cross_workspace_managed_dataset_access_is_denied(acceptance_client):
    response = acceptance_client.get(
        f"/v1/managed-datasets/{DATASET}",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": "other-workspace",
            # The route ID is the managed-dataset resource boundary.
            "X-InsightFlow-Resource-ID": RESOURCE,
        },
    )
    assert response.status_code == 403


@pytest.mark.xfail(
    strict=True,
    reason="Current middleware uses a supplied resource header before the route dataset ID.",
)
def test_managed_dataset_route_id_overrides_generic_resource_header(acceptance_client, monkeypatch):
    observed = []

    def record_authorize(claims, workspace_id, action, resource_id=None):
        observed.append((action, resource_id))
        return {"allowed": True}

    monkeypatch.setattr("firebase_authz.supabase_provider.authorize", record_authorize)
    response = acceptance_client.get(
        f"/v1/managed-datasets/{DATASET}/profile",
        headers={
            "Authorization": "Bearer valid",
            "X-InsightFlow-Workspace-ID": WORKSPACE,
            "X-InsightFlow-Resource-ID": "wrong-dataset",
        },
    )
    assert response.status_code == 200
    assert observed == [("dataset.view_original", DATASET)]
