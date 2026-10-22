from firebase_authz.routes import router


def test_company_registration_uses_authoritative_bootstrap_route():
    routes = {
        (route.path, method)
        for route in router.routes
        for method in getattr(route, "methods", set())
    }
    assert ("/v1/authz/organizations/register", "POST") in routes


def test_founder_registration_requires_supabase_auth_and_registration_fields(monkeypatch):
    from firebase_authz import routes

    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        "firebase_authz.supabase_auth.verify_supabase_access_token",
        lambda token, require_email_verified=True: {
            "uid": "verified-user",
            "sub": "verified-user",
            "email": "owner@example.com",
            "email_verified": True,
            "email_confirmed_at": "2026-10-01T00:00:00Z",
        },
    )
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.register_organization",
        lambda *args, **kwargs: {
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
        json={
            "organization_name": "ABC",
            "branch_name": "Main",
            "branch_identifier": "main",
            "full_name": "Owner Example",
            "phone": "+919876543210",
            "phone_country_calling_code": "+91",
            "phone_national_number": "9876543210",
            "address_line1": "1 Main Road",
            "state": "West Bengal",
            "state_code": "IN-WB",
            "postal_code": "700001",
            "country": "India",
            "country_code": "IN",
            "id_proof_type": "passport",
            "id_proof_number": "TEST-OWNER-001",
        },
        headers={"Authorization": "Bearer valid-supabase-token"},
    )
    assert response.status_code == 200
    assert response.json()["workspace_id"] == "org_opaque"


def test_founder_registration_rejects_missing_bearer(monkeypatch):
    from main import app
    from fastapi.testclient import TestClient

    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
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
        headers={"Authorization": "Bearer verified-supabase-token"},
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
