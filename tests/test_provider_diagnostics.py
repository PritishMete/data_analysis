import os

from fastapi.testclient import TestClient


def test_provider_diagnostics_reports_safe_normalized_provider(monkeypatch):
    from firebase_authz import routes
    from main import app

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "  SuPABASE ")
    monkeypatch.setenv("BUILD_GIT_SHA", "diagnostic-commit")
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "diagnostic-user"})

    response = TestClient(app).get(
        "/v1/authz/provider-diagnostics",
        headers={"Authorization": "Bearer diagnostic-token"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "provider": "supabase",
        "environment_variable_present": True,
        "backend_commit": "diagnostic-commit",
        "python_version": response.json()["python_version"],
        "module": "firebase_authz.routes",
    }


def test_provider_diagnostics_does_not_return_secrets(monkeypatch):
    from firebase_authz import routes
    from main import app

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "must-not-appear")
    monkeypatch.setenv("DATABASE_URL", "postgresql://secret-password@example.invalid/db")
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "diagnostic-user"})

    response = TestClient(app).get(
        "/v1/authz/provider-diagnostics",
        headers={"Authorization": "Bearer diagnostic-token"},
    )

    body = response.text
    assert response.status_code == 200
    assert "must-not-appear" not in body
    assert "secret-password" not in body
    assert "DATABASE_URL" not in body


def test_registration_dispatch_remains_provider_based(monkeypatch):
    from firebase_authz import routes
    from main import app

    calls = []
    monkeypatch.setattr(routes, "verify_id_token", lambda token: {"uid": "new-user"})
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.register_organization",
        lambda claims, name: calls.append(("supabase", name)) or {"provider": "supabase"},
    )
    monkeypatch.setattr(
        routes,
        "bootstrap_owner",
        lambda token, name, allow_any_authenticated=False: calls.append(("firebase", name, allow_any_authenticated)) or {"provider": "firebase"},
    )

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    supabase_response = TestClient(app).post(
        "/v1/authz/organizations/register",
        json={"organization_name": "Diagnostic Org"},
        headers={"Authorization": "Bearer diagnostic-token"},
    )
    assert supabase_response.status_code == 200
    assert supabase_response.json() == {"provider": "supabase"}

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "firebase")
    firebase_response = TestClient(app).post(
        "/v1/authz/organizations/register",
        json={"organization_name": "Diagnostic Org"},
        headers={"Authorization": "Bearer diagnostic-token"},
    )
    assert firebase_response.status_code == 200
    assert firebase_response.json() == {"provider": "firebase"}
    assert calls == [
        ("supabase", "Diagnostic Org"),
        ("firebase", "Diagnostic Org", True),
    ]
