"""Supabase-only authentication primitives and shared authorization errors.

This module intentionally has no Firebase SDK or persistence dependency. All
bearer tokens are verified by Supabase Auth; authorization records live in
PostgreSQL through `supabase_provider`.
"""
from __future__ import annotations

from typing import Any


class AuthzError(Exception):
    pass


class AuthenticationRequired(AuthzError):
    pass


class EmailVerificationRequired(AuthenticationRequired):
    pass


class PermissionDenied(AuthzError):
    pass


class BootstrapDenied(AuthzError):
    pass


def verify_id_token(id_token: str) -> dict[str, Any]:
    """Verify a Supabase Auth access token; never accept Firebase tokens."""
    if not id_token:
        raise AuthenticationRequired("Supabase authentication required.")
    from .supabase_auth import verify_supabase_access_token

    return verify_supabase_access_token(id_token)


def require_email_verified(claims: dict[str, Any]) -> dict[str, Any]:
    if claims.get("email_verified") is not True:
        raise EmailVerificationRequired("Email verification required.")
    return claims


def authenticated_identity(claims: dict[str, Any]) -> dict[str, Any]:
    """Normalize the stable subject from a verified Supabase Auth identity."""
    subject = str(claims.get("sub") or "").strip()
    if not subject:
        raise AuthenticationRequired("Supabase authentication failed.")
    uid = str(claims.get("uid") or subject).strip()
    if uid != subject:
        raise AuthenticationRequired("Supabase authentication failed.")
    return {
        "provider": "supabase",
        "provider_subject": subject,
        "verified_email": str(claims.get("email") or "").strip().lower(),
        "auth_uid": subject,
        "display_name": claims.get("name") or (claims.get("user_metadata") or {}).get("full_name"),
    }
