from firebase_authz.routes import router


def test_company_registration_uses_authoritative_bootstrap_route():
    routes = {
        (route.path, method)
        for route in router.routes
        for method in getattr(route, "methods", set())
    }
    assert ("/v1/authz/organizations/register", "POST") in routes


def test_founder_registration_requires_only_bearer_and_organization_name(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setattr(
        routes,
        "bootstrap_owner",
        lambda token, organization_name: {
            "organization_id": "org_opaque",
            "workspace_id": "org_opaque",
            "owner_uid": "verified-user",
        },
    )
    from main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    response = client.post(
        "/v1/authz/organizations/register",
        json={"organization_name": "ABC"},
        headers={"Authorization": "Bearer verified-firebase-token"},
    )
    assert response.status_code == 200
    assert response.json()["workspace_id"] == "org_opaque"


def test_founder_registration_rejects_missing_bearer(monkeypatch):
    from main import app
    from fastapi.testclient import TestClient

    response = TestClient(app).post(
        "/v1/authz/organizations/register",
        json={"organization_name": "ABC"},
    )
    assert response.status_code == 401


def test_founder_registration_cannot_accept_privileged_client_fields():
    from main import app
    from fastapi.testclient import TestClient

    response = TestClient(app).post(
        "/v1/authz/organizations/register",
        json={
            "organization_name": "ABC",
            "workspace_id": "attacker-chosen",
            "expected_uid": "attacker-user",
            "bootstrap_secret": "attacker-secret",
            "role": "organization_owner",
        },
        headers={"Authorization": "Bearer verified-firebase-token"},
    )
    assert response.status_code == 422


def test_production_cors_allows_github_pages_authorized_post():
    from main import app
    from fastapi.testclient import TestClient

    response = TestClient(app).options(
        "/v1/authz/organizations/register",
        headers={
            "Origin": "https://pritishmete.github.io",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type",
        },
    )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "https://pritishmete.github.io"
    assert "authorization" in response.headers["access-control-allow-headers"].lower()
