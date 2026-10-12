import pytest

from firebase_authz import service, supabase_auth


def test_verify_id_token_always_uses_supabase_even_if_legacy_mode_is_set(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "firebase")
    monkeypatch.setattr(
        supabase_auth,
        "verify_supabase_access_token",
        lambda token: {"uid": "supabase-user", "sub": "supabase-user", "provider": "supabase"},
    )
    monkeypatch.setattr(
        service,
        "initialize_firebase",
        lambda: pytest.fail("Firebase initialization must not be used to verify tokens"),
    )

    claims = service.verify_id_token("supabase-access-token")

    assert claims["uid"] == "supabase-user"
    assert claims["provider"] == "supabase"


def test_invalid_supabase_token_is_rejected_without_firebase_fallback(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "dual")

    def reject(_token):
        raise service.AuthenticationRequired("Supabase authentication failed.")

    monkeypatch.setattr(supabase_auth, "verify_supabase_access_token", reject)
    monkeypatch.setattr(
        service,
        "initialize_firebase",
        lambda: pytest.fail("Firebase fallback must never run"),
    )

    with pytest.raises(service.AuthenticationRequired, match="Supabase authentication failed"):
        service.verify_id_token("firebase-looking-token")


def test_identity_binding_ignores_firebase_claims():
    provider, subject = service._claims_identity_binding(
        {
            "uid": "supabase-user",
            "sub": "supabase-user",
            "firebase": {
                "sign_in_provider": "google.com",
                "identities": {"google.com": ["google-subject"]},
            },
        }
    )

    assert provider == "supabase"
    assert subject == "supabase-user"
