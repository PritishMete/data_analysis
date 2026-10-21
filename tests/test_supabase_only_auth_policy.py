import pytest

from firebase_authz import service
from firebase_authz.service import AuthenticationRequired


@pytest.mark.parametrize("mode", [None, "", "   ", "firebase", "dual", "supabasee", "unknown"])
def test_authentication_provider_configuration_fails_closed(monkeypatch, mode):
    if mode is None:
        monkeypatch.delenv("AUTHN_PROVIDER_MODE", raising=False)
    else:
        monkeypatch.setenv("AUTHN_PROVIDER_MODE", mode)

    def firebase_must_not_run(*args, **kwargs):
        pytest.fail("Firebase token verification must never be used")

    monkeypatch.setattr(service, "initialize_firebase", firebase_must_not_run)
    with pytest.raises(AuthenticationRequired, match="Supabase authentication is required"):
        service.verify_id_token("header.payload.signature")


def test_supabase_mode_delegates_token_verification_to_supabase(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    expected = {"uid": "trusted-subject", "provider": "supabase"}
    called = {}

    def verify(token):
        called["token"] = token
        return expected

    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", verify)
    assert service.verify_id_token("supabase-token") == expected
    assert called == {"token": "supabase-token"}


@pytest.mark.parametrize("token", ["", " ", None])
def test_missing_token_fails_closed_even_with_supabase_configured(monkeypatch, token):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    with pytest.raises(AuthenticationRequired):
        service.verify_id_token(token)


def test_firebase_shaped_token_is_not_routed_to_firebase(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")

    def firebase_must_not_run(*args, **kwargs):
        pytest.fail("Firebase token verification must never be used")

    monkeypatch.setattr(service, "initialize_firebase", firebase_must_not_run)

    def reject_supabase(token):
        raise AuthenticationRequired("Supabase token verification failed.")

    monkeypatch.setattr("firebase_authz.supabase_auth.verify_supabase_access_token", reject_supabase)
    with pytest.raises(AuthenticationRequired, match="Supabase token verification failed"):
        service.verify_id_token("firebase-shaped-token")


@pytest.mark.parametrize("mode", [None, "", "firebase", "dual", "invalid"])
def test_management_claims_reject_non_supabase_provider(monkeypatch, mode):
    from fastapi import HTTPException
    from firebase_authz import management_routes

    if mode is None:
        monkeypatch.delenv("AUTHN_PROVIDER_MODE", raising=False)
    else:
        monkeypatch.setenv("AUTHN_PROVIDER_MODE", mode)

    def verifier_must_not_run(*args, **kwargs):
        pytest.fail("Supabase token verifier must not run with invalid provider configuration")

    monkeypatch.setattr(management_routes, "verify_supabase_access_token", verifier_must_not_run)
    with pytest.raises(HTTPException) as exc:
        management_routes._claims("Bearer any-token")
    assert exc.value.status_code == 401


def test_management_claims_reject_missing_authorization(monkeypatch):
    from fastapi import HTTPException
    from firebase_authz import management_routes

    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    with pytest.raises(HTTPException) as exc:
        management_routes._claims(None)
    assert exc.value.status_code == 401


def test_management_claims_use_supabase_verifier_only(monkeypatch):
    from firebase_authz import management_routes

    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    expected = {"uid": "verified-subject", "provider": "supabase", "email_verified": True}
    captured = {}

    def verify(token, require_email_verified=False):
        captured["token"] = token
        captured["require_email_verified"] = require_email_verified
        return expected

    monkeypatch.setattr(management_routes, "verify_supabase_access_token", verify)
    assert management_routes._claims("Bearer valid-supabase-token") == expected
    assert captured == {
        "token": "valid-supabase-token",
        "require_email_verified": True,
    }


def test_organization_registration_rejects_missing_authn_provider_mode(monkeypatch):
    from fastapi import HTTPException
    from firebase_authz import routes

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.delenv("AUTHN_PROVIDER_MODE", raising=False)

    def registration_must_not_run(*args, **kwargs):
        pytest.fail("Organization registration must not bypass the provider policy")

    monkeypatch.setattr("firebase_authz.supabase_provider.register_organization", registration_must_not_run)

    with pytest.raises(HTTPException) as exc:
        routes.founder_organization_register(
            routes.FounderOrganizationRegistration(),
            authorization="Bearer token",
        )
    assert exc.value.status_code == 401
