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


def test_supabase_auth_api_failure_is_rejected(monkeypatch):
    _verified_jwt_setup(monkeypatch, {"id": "supabase-user"})
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda *args, **kwargs: (_ for _ in ()).throw(OSError("unavailable")),
    )
    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token("token")


def test_unsupported_jwt_algorithm_is_rejected_without_auth_api_fallback(monkeypatch):
    import time
    import jwt

    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")

    class Key:
        key = "shared-secret"

    class Jwks:
        def get_signing_key_from_jwt(self, token):
            return Key()

    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda url: Jwks())
    monkeypatch.setattr(
        supabase_auth,
        "_fetch_supabase_user",
        lambda token: pytest.fail("Unsupported JWT algorithms must not trigger fallback verification."),
    )
    now = int(time.time())
    token = jwt.encode(
        {
            "sub": "10000000-0000-4000-8000-000000000001",
            "aud": "authenticated",
            "iss": "https://project.supabase.co/auth/v1",
            "iat": now,
            "exp": now + 600,
        },
        "shared-secret",
        algorithm="HS256",
        headers={"kid": "unsupported-algorithm"},
    )

    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token(token)


def test_invalid_jwt_signature_is_rejected_without_auth_api_fallback(monkeypatch):
    import time
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    signing_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    wrong_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = signing_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    wrong_public_pem = wrong_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    class Key:
        key = wrong_public_pem

    class Jwks:
        def get_signing_key_from_jwt(self, token):
            return Key()

    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda url: Jwks())
    monkeypatch.setattr(
        supabase_auth,
        "_fetch_supabase_user",
        lambda token: pytest.fail("Invalid signatures must not trigger fallback verification."),
    )
    now = int(time.time())
    token = jwt.encode(
        {
            "sub": "10000000-0000-4000-8000-000000000002",
            "aud": "authenticated",
            "iss": "https://project.supabase.co/auth/v1",
            "iat": now,
            "exp": now + 600,
        },
        private_pem,
        algorithm="RS256",
        headers={"kid": "wrong-signature"},
    )

    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token(token)


def test_expired_supabase_jwt_is_rejected_before_auth_user_lookup(monkeypatch):
    import time
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    signing_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = signing_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = signing_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    class Key:
        key = public_pem

    class Jwks:
        def get_signing_key_from_jwt(self, token):
            return Key()

    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    monkeypatch.setattr(supabase_auth, "_jwks_client", lambda url: Jwks())
    monkeypatch.setattr(
        supabase_auth,
        "_fetch_supabase_user",
        lambda *args, **kwargs: pytest.fail("Expired JWT must be rejected before user lookup."),
    )
    now = int(time.time())
    token = jwt.encode(
        {
            "sub": "10000000-0000-4000-8000-000000000003",
            "aud": "authenticated",
            "iss": "https://project.supabase.co/auth/v1",
            "iat": now - 600,
            "exp": now - 300,
        },
        private_pem,
        algorithm="RS256",
        headers={"kid": "expired-token"},
    )

    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.verify_supabase_access_token(token)
