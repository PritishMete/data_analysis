"""Trusted-server Supabase Auth Admin helpers.

This module is intentionally server-only. No Flutter/Web code imports it.
"""
from __future__ import annotations

import os
from typing import Any

from supabase import create_client
from supabase.lib.client_options import ClientOptions


def _supabase_url() -> str:
    url = os.environ.get("SUPABASE_URL", "").strip()
    if url:
        return url.rstrip("/")
    project_ref = os.environ.get("SUPABASE_PROJECT_REF", "").strip()
    if project_ref:
        return f"https://{project_ref}.supabase.co"
    raise RuntimeError(
        "Supabase Auth Admin URL is not configured. Set SUPABASE_URL or SUPABASE_PROJECT_REF."
    )


def _supabase_secret() -> str:
    secret = (
        os.environ.get("SUPABASE_SECRET_KEY", "").strip()
        or os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    )
    if not secret:
        raise RuntimeError(
            "Employee invitation email requires the server-only SUPABASE_SECRET_KEY "
            "(or legacy SUPABASE_SERVICE_ROLE_KEY) environment variable."
        )
    return secret


def admin_client():
    return create_client(
        _supabase_url(),
        _supabase_secret(),
        options=ClientOptions(
            auto_refresh_token=False,
            persist_session=False,
            detect_session_in_url=False,
        ),
    )


def invite_user_by_email(email: str, redirect_to: str) -> dict[str, Any]:
    response = admin_client().auth.admin.invite_user_by_email(
        email,
        options={"redirect_to": redirect_to},
    )
    user = getattr(response, "user", None)
    if user is None and isinstance(response, dict):
        user = response.get("user")
    if user is None:
        raise RuntimeError("Supabase Auth did not return the invited user.")
    user_id = getattr(user, "id", None) or (user.get("id") if isinstance(user, dict) else None)
    confirmed = getattr(user, "email_confirmed_at", None)
    if confirmed is None and isinstance(user, dict):
        confirmed = user.get("email_confirmed_at")
    return {
        "user_id": str(user_id or "").strip(),
        "email_confirmed": confirmed is not None,
    }


def find_user_by_email(email: str) -> dict[str, Any] | None:
    client = admin_client()
    page = 1
    while True:
        response = client.auth.admin.list_users(page=page, per_page=1000)
        users = getattr(response, "users", None)
        if users is None and isinstance(response, dict):
            users = response.get("users")
        users = users or []
        for user in users:
            value = getattr(user, "email", None)
            if value is None and isinstance(user, dict):
                value = user.get("email")
            if str(value or "").strip().lower() != email:
                continue
            user_id = getattr(user, "id", None) or (user.get("id") if isinstance(user, dict) else None)
            confirmed = getattr(user, "email_confirmed_at", None)
            if confirmed is None and isinstance(user, dict):
                confirmed = user.get("email_confirmed_at")
            return {
                "user_id": str(user_id or "").strip(),
                "email_confirmed": confirmed is not None,
            }
        if len(users) < 1000:
            return None
        page += 1
