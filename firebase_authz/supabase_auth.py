from __future__ import annotations

import os
import json
import urllib.request
from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient

from .service import AuthenticationRequired

JWT_CLOCK_SKEW_LEEWAY_SECONDS = 10

def _setting(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _project_url() -> str:
    value = _setting("SUPABASE_URL")
    if not value:
        ref = _setting("SUPABASE_PROJECT_REF")
        value = f"https://{ref}.supabase.co" if ref else ""
    return value.rstrip("/")


def _issuer() -> str:
    return _setting("SUPABASE_AUTH_ISSUER", f"{_project_url()}/auth/v1")


def _publishable_key() -> str:
    return _setting("SUPABASE_PUBLISHABLE_KEY") or _setting(
        "INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY"
    )


@lru_cache(maxsize=4)
def _jwks_client(url: str) -> PyJWKClient:
    return PyJWKClient(url, cache_jwk_set=True, lifespan=300)


def _confirmed_supabase_user(token: str, subject: str) -> bool:
    """Read confirmed state from Supabase Auth, never from client claims."""
    key = _publishable_key()
    if not key:
        raise AuthenticationRequired("Supabase authentication is not configured.")
    request = urllib.request.Request(
        f"{_project_url()}/auth/v1/user",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {token}",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            user = json.loads(response.read())
    except Exception as exc:
        raise AuthenticationRequired("Supabase user state could not be verified.") from exc
    if not isinstance(user, dict) or str(user.get("id") or "").strip() != subject:
        raise AuthenticationRequired("Supabase user identity does not match the token.")
    return bool(user.get("email_confirmed_at"))


def verify_supabase_access_token(token: str) -> dict[str, Any]:
    """Verify a Supabase Auth access token without using a signing secret."""
    if not token:
        raise AuthenticationRequired("Supabase authentication required.")
    issuer = _issuer()
    if not issuer or not _project_url():
        raise AuthenticationRequired("Supabase authentication is not configured.")
    try:
        signing_key = _jwks_client(f"{_project_url()}/auth/v1/.well-known/jwks.json").get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["ES256", "RS256"],
            audience=_setting("SUPABASE_AUTH_AUDIENCE", "authenticated"),
            issuer=issuer,
            leeway=JWT_CLOCK_SKEW_LEEWAY_SECONDS,
            options={"require": ["sub", "exp", "iat"]},
        )
    except Exception as exc:
        raise AuthenticationRequired("Supabase authentication failed.") from exc
    subject = str(claims.get("sub") or "").strip()
    if not subject:
        raise AuthenticationRequired("Supabase authentication failed.")
    claims["uid"] = subject
    claims["provider"] = "supabase"
    claims["email_verified"] = _confirmed_supabase_user(token, subject)
    if not claims["email_verified"]:
        raise AuthenticationRequired("Email verification required.")
    return claims
