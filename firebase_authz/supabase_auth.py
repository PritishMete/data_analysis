from __future__ import annotations

import os
import json
import urllib.request
from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient

from .service import AuthenticationRequired
from . import registration_diagnostics

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


def _fetch_supabase_user(token: str, subject: str | None = None) -> dict[str, Any]:
    """Validate the access token against Supabase Auth and return its user.

    This is the authoritative verification path for legacy HS256 projects.
    It also gives the backend a safe fallback for token states that cannot be
    verified through the public JWKS endpoint.
    """
    registration_diagnostics.stage("SUPABASE_USER_LOOKUP_START")
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
    user_id = str(user.get("id") or "").strip() if isinstance(user, dict) else ""
    if not user_id or (subject is not None and user_id != subject):
        raise AuthenticationRequired("Supabase user identity does not match the token.")
    registration_diagnostics.stage("SUPABASE_USER_LOOKUP_COMPLETE")
    return user


def _confirmed_supabase_user(token: str, subject: str) -> bool:
    """Read confirmed state from Supabase Auth, never from client claims."""
    return bool(_fetch_supabase_user(token, subject).get("email_confirmed_at"))


def verify_supabase_access_token(token: str, require_email_verified: bool = True) -> dict[str, Any]:
    """Verify a Supabase Auth access token without using a signing secret."""
    if not token:
        raise AuthenticationRequired("Supabase authentication required.")
    issuer = _issuer()
    if not issuer or not _project_url():
        raise AuthenticationRequired("Supabase authentication is not configured.")
    try:
        signing_key = _jwks_client(
            f"{_project_url()}/auth/v1/.well-known/jwks.json"
        ).get_signing_key_from_jwt(token)
    except Exception as exc:
        # Supabase's legacy HS256 projects intentionally expose no asymmetric
        # key in JWKS. Per Supabase guidance, validate those tokens through the
        # Auth /user endpoint instead of storing the JWT secret in this backend.
        # The fallback is only for key-discovery failures; once a signing key
        # has been obtained, JWT validation errors must remain authoritative.
        try:
            user = _fetch_supabase_user(token)
            subject = str(user.get("id") or "").strip()
            if not subject:
                raise AuthenticationRequired("Supabase authentication failed.")
            claims = {
                "sub": subject,
                "email": user.get("email"),
                "email_confirmed_at": user.get("email_confirmed_at"),
                "phone": user.get("phone"),
                "phone_confirmed_at": user.get("phone_confirmed_at"),
                "aud": "authenticated",
            }
            registration_diagnostics.stage("SUPABASE_AUTH_SERVER_FALLBACK_COMPLETE")
        except AuthenticationRequired:
            raise
        except Exception as fallback_exc:
            raise AuthenticationRequired("Supabase authentication failed.") from fallback_exc
    else:
        try:
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["ES256", "RS256"],
                audience=_setting("SUPABASE_AUTH_AUDIENCE", "authenticated"),
                issuer=issuer,
                leeway=JWT_CLOCK_SKEW_LEEWAY_SECONDS,
                options={"require": ["sub", "exp", "iat"]},
            )
            registration_diagnostics.stage("JWKS_OR_TOKEN_VERIFICATION_COMPLETE")
        except jwt.InvalidTokenError as exc:
            raise AuthenticationRequired("Supabase authentication failed.") from exc
    subject = str(claims.get("sub") or "").strip()
    if not subject:
        raise AuthenticationRequired("Supabase authentication failed.")
    claims["uid"] = subject
    claims["provider"] = "supabase"
    if require_email_verified:
        authoritative_user = _fetch_supabase_user(token, subject)
        claims["email_verified"] = bool(authoritative_user.get("email_confirmed_at"))
        claims["email_confirmed_at"] = authoritative_user.get("email_confirmed_at")
        claims["phone"] = authoritative_user.get("phone")
        claims["phone_confirmed_at"] = authoritative_user.get("phone_confirmed_at")
        if not claims["email_verified"]:
            raise AuthenticationRequired("Email verification required.")
    else:
        # Registration only requires a valid Supabase Auth session. It does not
        # perform email/KYC/company verification; organization membership is
        # created by the onboarding transaction.
        claims["email_verified"] = bool(claims.get("email_verified"))
    return claims
