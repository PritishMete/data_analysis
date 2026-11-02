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
    monkeypatch.setattr(
        supabase_auth,
        "_fetch_supabase_user",
        lambda token, subject=None: {
            "id": subject or "supabase-user",
            "email": "user@example.com",
            "email_confirmed_at": "2026-01-01T00:00:00Z",
            "phone": "+15551234567",
            "phone_confirmed_at": "2026-01-01T00:00:00Z",
        },
    )
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
    import urllib.error

    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY", "publishable-test-key")
    monkeypatch.setattr(
        supabase_auth, "_jwks_client",
        lambda _: (_ for _ in ()).throw(RuntimeError("unsupported signing key")),
    )
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            urllib.error.HTTPError(
                "https://example.supabase.co/auth/v1/user", 401,
                "invalid token", {}, None
            )
        ),
    )
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
    monkeypatch.setattr(
        supabase_auth,
        "_fetch_supabase_user",
        lambda token, subject=None: {
            "id": subject or "supabase-user",
            "email": "user@example.com",
            "email_confirmed_at": "2026-01-01T00:00:00Z",
            "phone": "+15551234567",
            "phone_confirmed_at": "2026-01-01T00:00:00Z",
        },
    )

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


def test_supabase_auth_api_network_failure_is_temporary(monkeypatch):
    _verified_jwt_setup(monkeypatch, {"id": "supabase-user"})
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(OSError("unavailable")),
    )
    with pytest.raises(supabase_auth.SupabaseAuthUnavailable):
        supabase_auth.verify_supabase_access_token("token")


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (401, supabase_auth.AuthenticationRequired),
        (403, supabase_auth.AuthenticationRequired),
        (429, supabase_auth.SupabaseAuthUnavailable),
        (503, supabase_auth.SupabaseAuthUnavailable),
    ],
)
def test_supabase_auth_http_errors_distinguish_credentials_from_outages(
    monkeypatch, status, expected
):
    import urllib.error

    _verified_jwt_setup(monkeypatch, {"id": "supabase-user"})
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            urllib.error.HTTPError(
                "https://example.supabase.co/auth/v1/user", status,
                "upstream", {}, None
            )
        ),
    )
    with pytest.raises(expected):
        supabase_auth.verify_supabase_access_token("token")


def test_authz_me_returns_503_when_supabase_auth_is_unavailable(monkeypatch):
    from fastapi import HTTPException
    from firebase_authz import routes

    monkeypatch.setenv("AUTHN_PROVIDER_MODE", "supabase")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")

    def unavailable(_token):
        raise supabase_auth.SupabaseAuthUnavailable("Supabase Auth unavailable")

    monkeypatch.setattr(routes, "verify_id_token", unavailable)
    with pytest.raises(HTTPException) as error:
        routes.me("Bearer valid-shaped-token")
    assert error.value.status_code == 503
