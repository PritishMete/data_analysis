import jwt
import pytest
import time

from firebase_authz import supabase_auth


def test_supabase_claims_are_normalized(monkeypatch):
    class Key:
        key = "unused"

    class Client:
        def get_signing_key_from_jwt(self, token):
            return Key()

    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda _: Client())
    monkeypatch.setattr(supabase_auth, "_confirmed_supabase_user", lambda token, subject: True)
    monkeypatch.setattr(
        jwt,
        "decode",
        lambda *args, **kwargs: {
            "sub": "supabase-user",
            "email": "user@example.com",
            "email_confirmed_at": "2026-01-01T00:00:00Z",
        },
    )
    claims = supabase_auth.verify_supabase_access_token("header.payload.signature")
    assert claims["uid"] == "supabase-user"
    assert claims["provider"] == "supabase"
    assert claims["email_verified"] is True


def test_supabase_invalid_token_is_rejected(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda _: (_ for _ in ()).throw(RuntimeError("bad key")))
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("bad.token.value")


def test_supabase_timestamp_validation_uses_bounded_clock_skew(monkeypatch):
    class Key:
        key = "unused"

    class Client:
        def get_signing_key_from_jwt(self, token):
            return Key()

    captured = {}
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda _: Client())
    monkeypatch.setattr(supabase_auth, "_confirmed_supabase_user", lambda token, subject: True)

    def decode(_token, _key, **kwargs):
        captured.update(kwargs)
        return {"sub": "user", "iat": time.time() + 3, "exp": time.time() + 300}

    monkeypatch.setattr(jwt, "decode", decode)
    claims = supabase_auth.verify_supabase_access_token("header.payload.signature")
    assert claims["uid"] == "user"
    assert captured["leeway"] == 10

    def far_future_decode(_token, _key, **kwargs):
        captured.update(kwargs)
        raise jwt.ImmatureSignatureError("future token")

    monkeypatch.setattr(jwt, "decode", far_future_decode)
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("header.payload.signature")


def _verified_jwt_setup(monkeypatch, user_response):
    class Key:
        key = "unused"

    class Client:
        def get_signing_key_from_jwt(self, token):
            return Key()

    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY", "publishable-test-key")
    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda _: Client())
    monkeypatch.setattr(
        jwt,
        "decode",
        lambda *args, **kwargs: {
            "sub": "supabase-user",
            "iat": time.time(),
            "exp": time.time() + 300,
            "iss": "https://example.supabase.co/auth/v1",
            "aud": "authenticated",
        },
    )

    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return json.dumps(user_response).encode()

    import json
    monkeypatch.setattr(supabase_auth.urllib.request, "urlopen", lambda *args, **kwargs: Response())


def test_confirmed_auth_user_sets_normalized_verification(monkeypatch):
    _verified_jwt_setup(
        monkeypatch,
        {"id": "supabase-user", "email_confirmed_at": "2026-09-25T00:00:00Z"},
    )
    claims = supabase_auth.verify_supabase_access_token("token")
    assert claims["email_verified"] is True


def test_unconfirmed_auth_user_is_rejected_even_if_jwt_claims_say_true(monkeypatch):
    _verified_jwt_setup(monkeypatch, {"id": "supabase-user"})
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("token")


def test_supabase_user_subject_mismatch_is_rejected(monkeypatch):
    _verified_jwt_setup(
        monkeypatch,
        {"id": "different-user", "email_confirmed_at": "2026-09-25T00:00:00Z"},
    )
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("token")


def test_supabase_auth_api_failure_is_rejected(monkeypatch):
    _verified_jwt_setup(monkeypatch, {"id": "supabase-user"})
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(OSError("unavailable")),
    )
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("token")
