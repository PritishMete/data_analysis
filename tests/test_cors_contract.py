from fastapi.testclient import TestClient

from main import app


PAGES_ORIGIN = "https://insightflow-3e8.pages.dev"
UNAPPROVED_ORIGIN = "https://unapproved.example"
REQUIRED_HEADERS = [
    "authorization",
    "content-type",
    "x-insightflow-workspace-id",
    "x-insightflow-resource-id",
    "x-insightflow-location-id",
    "x-insightflow-dataset-id",
    "x-insightflow-version",
    "x-insightflow-branch-id",
]


def test_pages_preflight_accepts_every_required_header():
    response = TestClient(app).options(
        "/v1/authz/me",
        headers={
            "Origin": PAGES_ORIGIN,
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": ",".join(REQUIRED_HEADERS),
        },
    )

    assert response.status_code in (200, 204)
    assert response.headers["access-control-allow-origin"] == PAGES_ORIGIN
    allowed_headers = response.headers["access-control-allow-headers"].lower()
    assert all(header in allowed_headers for header in REQUIRED_HEADERS)


def test_unapproved_origin_is_not_granted_cors_access():
    response = TestClient(app).options(
        "/v1/authz/me",
        headers={
            "Origin": UNAPPROVED_ORIGIN,
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization",
        },
    )

    assert "access-control-allow-origin" not in response.headers


def test_pages_actual_response_preserves_cors_and_authorization_contract():
    response = TestClient(app).get(
        "/v1/authz/me",
        headers={
            "Origin": PAGES_ORIGIN,
            "Authorization": "Bearer test-token",
        },
    )

    assert response.status_code in (401, 403)
    assert response.headers["access-control-allow-origin"] == PAGES_ORIGIN

