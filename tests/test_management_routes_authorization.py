"""HTTP-boundary authorization regression matrix for management routes.

These tests intentionally exercise every management endpoint without touching
PostgreSQL. They verify that route handlers cannot be reached without a verified
Supabase bearer token and that a verified token cannot omit workspace context.
Domain-level role/scope tests remain in test_management_domain.py.
"""
import pytest
from fastapi.testclient import TestClient

from firebase_authz import management_routes


# Keep this list aligned with the route inventory in management_routes.py.
# The query/body values satisfy FastAPI validation so the assertion reaches
# the authentication/workspace guard rather than failing request validation.
MANAGEMENT_ENDPOINTS = [
    ("GET", "/v1/authz/management/overview", None, None),
    ("GET", "/v1/authz/management/locations", None, None),
    ("POST", "/v1/authz/management/locations", None, {"name": "Branch", "branch_identifier": "BR-1"}),
    ("GET", "/v1/authz/management/sections", None, None),
    ("POST", "/v1/authz/management/sections", None, {"location_id": "loc-test", "name": "Section"}),
    ("GET", "/v1/authz/management/people", None, None),
    ("GET", "/v1/authz/management/assignments", None, None),
    ("GET", "/v1/authz/management/assignments/asg-test/profile", None, None),
    ("POST", "/v1/authz/management/assignments/manager", None, {"location_id": "loc-test", "principal_id": "prn-test"}),
    ("POST", "/v1/authz/management/assignments/manager/change", None, {"location_id": "loc-test", "principal_id": "prn-test"}),
    ("POST", "/v1/authz/management/assignments/team-lead", None, {"location_id": "loc-test", "section_id": "sec-test", "principal_id": "prn-test"}),
    ("GET", "/v1/authz/management/assignments/team-lead/requests", None, None),
    ("POST", "/v1/authz/management/assignments/team-lead/request", None, {"location_id": "loc-test", "section_id": "sec-test", "principal_id": "prn-test"}),
    ("POST", "/v1/authz/management/assignments/team-lead/requests/req-test/decision", {"approve": "true"}, None),
    ("POST", "/v1/authz/management/assignments/reporting", None, {"assignment_id": "asg-test", "reports_to_assignment_id": None}),
    ("GET", "/v1/authz/management/data-access/catalog", None, None),
    ("POST", "/v1/authz/management/data-access/requests", {"dataset_id": "ds-test"}, None),
    ("GET", "/v1/authz/management/data-access/requests", None, None),
    ("POST", "/v1/authz/management/data-access/requests/req-test/decision", {"approve": "true"}, None),
    ("POST", "/v1/authz/management/data-access/working-copies/assign", None, {"working_copy_id": "wc-test", "target_uid": "user-test"}),
    ("POST", "/v1/authz/management/data-access/working-copies/revoke", None, {"working_copy_id": "wc-test", "target_uid": "user-test"}),
    ("GET", "/v1/authz/management/audit", None, None),
]


def _request(client, method, path, query, body, headers):
    kwargs = {"headers": headers}
    if query:
        kwargs["params"] = query
    if body is not None:
        kwargs["json"] = body
    return client.request(method, path, **kwargs)


@pytest.mark.parametrize(
    ("method", "path", "query", "body"),
    MANAGEMENT_ENDPOINTS,
    ids=[f"{method}-{path}" for method, path, _, _ in MANAGEMENT_ENDPOINTS],
)
def test_every_management_endpoint_rejects_missing_bearer_token(
    method, path, query, body, monkeypatch
):
    from main import app

    client = TestClient(app)
    response = _request(client, method, path, query, body, {})
    assert response.status_code == 401, f"{method} {path}: {response.status_code} {response.text}"


@pytest.mark.parametrize(
    ("method", "path", "query", "body"),
    MANAGEMENT_ENDPOINTS,
    ids=[f"{method}-{path}" for method, path, _, _ in MANAGEMENT_ENDPOINTS],
)
def test_every_management_endpoint_requires_workspace_context(
    method, path, query, body, monkeypatch
):
    from main import app

    monkeypatch.setattr(
        management_routes,
        "verify_supabase_access_token",
        lambda token, require_email_verified=True: {
            "sub": "test-supabase-subject",
            "email_verified": True,
        },
    )
    client = TestClient(app)
    response = _request(
        client, method, path, query, body, {"Authorization": "Bearer valid-test-token"}
    )
    assert response.status_code == 400, f"{method} {path}: {response.status_code} {response.text}"
    assert "Workspace authorization context required" in response.text
