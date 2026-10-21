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
