import pytest

from firebase_authz import auth, supabase_auth, supabase_provider


def test_verify_id_token_always_uses_supabase_even_if_legacy_mode_is_set(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "firebase")
    monkeypatch.setattr(
        supabase_auth,
        "verify_supabase_access_token",
        lambda token: {"uid": "supabase-user", "sub": "supabase-user", "provider": "supabase"},
    )
    claims = auth.verify_id_token("supabase-access-token")

    assert claims["uid"] == "supabase-user"
    assert claims["provider"] == "supabase"


def test_invalid_supabase_token_is_rejected_without_firebase_fallback(monkeypatch):
    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "dual")

    def reject(_token):
        raise auth.AuthenticationRequired("Supabase authentication failed.")

    monkeypatch.setattr(supabase_auth, "verify_supabase_access_token", reject)
    with pytest.raises(auth.AuthenticationRequired, match="Supabase authentication failed"):
        auth.verify_id_token("firebase-looking-token")


def test_identity_binding_ignores_firebase_claims():
    provider, subject = supabase_provider._identity(
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
