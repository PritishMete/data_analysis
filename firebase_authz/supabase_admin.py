"""Trusted-server Supabase Auth Admin helpers.

This module is intentionally server-only. No Flutter/Web code imports it.
"""
from __future__ import annotations

import logging
import os
import re
from typing import Any, Callable

from supabase import create_client


logger = logging.getLogger(__name__)

_SECRET_KEY_ENV = "SUPABASE_SECRET_KEY"
_SERVICE_ROLE_ENV = "SUPABASE_SERVICE_ROLE_KEY"


class SupabaseAdminConfigurationError(RuntimeError):
    """The server is missing the URL or an Admin API credential."""


class SupabaseAdminOperationError(RuntimeError):
    """A trusted-server Supabase Auth Admin operation failed."""


class SupabaseAdminCredentialError(SupabaseAdminOperationError):
    """The configured Admin credential was rejected by Supabase."""


def _supabase_url() -> str:
    url = os.environ.get("SUPABASE_URL", "").strip()
    if url:
        return url.rstrip("/")
    project_ref = os.environ.get("SUPABASE_PROJECT_REF", "").strip()
    if project_ref:
        return f"https://{project_ref}.supabase.co"
    raise SupabaseAdminConfigurationError(
        "Supabase Auth Admin URL is not configured. Set SUPABASE_URL or SUPABASE_PROJECT_REF."
    )


def _credential_candidates() -> list[tuple[str, str]]:
    candidates: list[tuple[str, str]] = []
    secret = os.environ.get(_SECRET_KEY_ENV, "").strip()
    service_role = os.environ.get(_SERVICE_ROLE_ENV, "").strip()

    # Supabase recommends the new server-only secret key for Admin Auth.
    # Keep the legacy service_role key as a compatibility fallback while
    # projects migrate away from the legacy API keys.
    if secret:
        candidates.append((_SECRET_KEY_ENV, secret))
    if service_role and service_role != secret:
        candidates.append((_SERVICE_ROLE_ENV, service_role))

    if not candidates:
        raise SupabaseAdminConfigurationError(
            "Employee invitation email requires SUPABASE_SECRET_KEY "
            "(or legacy SUPABASE_SERVICE_ROLE_KEY)."
        )
    return candidates


def _supabase_secret() -> str:
    return _credential_candidates()[0][1]


def _credential_client(source: str, credential: str):
    logger.debug("supabase_admin_client source=%s url=%s", source, _supabase_url())
    return create_client(
        _supabase_url(),
        credential,
    )


def admin_client():
    source, credential = _credential_candidates()[0]
    return _credential_client(source, credential)


def _status_code(exc: Exception) -> int | None:
    value = getattr(exc, "status_code", None)
    if value is None:
        value = getattr(exc, "status", None)
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _is_admin_auth_failure(exc: Exception) -> bool:
    return _status_code(exc) in {401, 403}


def _sanitized_exception_message(exc: Exception) -> str:
    message = str(exc).strip() or exc.__class__.__name__
    # Never allow credentials or bearer tokens to enter server logs.
    message = re.sub(r"(?i)bearer\s+[^\s,;]+", "Bearer [REDACTED]", message)
    message = re.sub(r"(?i)(sb_secret|sb_publishable)_[A-Za-z0-9_-]+", r"\1_[REDACTED]", message)
    message = re.sub(r"(?i)eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "[JWT_REDACTED]", message)
    return message[:1000]


def _run_admin_operation(operation: str, callback: Callable[[Any], Any]):
    last_error: Exception | None = None
    candidates = _credential_candidates()
    for index, (source, credential) in enumerate(candidates):
        try:
            client = _credential_client(source, credential)
            return callback(client)
        except Exception as exc:
            last_error = exc
            logger.warning(
                "supabase_admin_failure operation=%s credential_source=%s "
                "status_code=%s exception_class=%s message=%s",
                operation,
                source,
                _status_code(exc),
                exc.__class__.__name__,
                _sanitized_exception_message(exc),
            )
            # Only try the legacy key when the preferred secret key was
            # explicitly rejected as an Admin credential. Preserve Supabase's
            # duplicate-user 422 so the invitation layer can resolve the
            # existing Auth account; wrap every other unexpected Admin error
            # in a safe service-operation exception.
            if not _is_admin_auth_failure(exc):
                message = _sanitized_exception_message(exc).lower()
                if _status_code(exc) == 422 and "already been registered" in message:
                    raise
                raise SupabaseAdminOperationError(
                    f"Supabase Auth Admin operation {operation} failed."
                ) from exc
            if index + 1 < len(candidates):
                logger.warning(
                    "supabase_admin_fallback operation=%s from=%s to=%s",
                    operation,
                    source,
                    candidates[index + 1][0],
                )
                continue
            break
    if last_error is not None and _is_admin_auth_failure(last_error):
        raise SupabaseAdminCredentialError(
            f"Supabase Auth Admin rejected all configured credentials for {operation}."
        ) from last_error
    if last_error is not None:
        raise SupabaseAdminOperationError(
            f"Supabase Auth Admin operation {operation} failed."
        ) from last_error
    raise SupabaseAdminOperationError(
        f"Supabase Auth Admin operation {operation} failed."
    )


def invite_user_by_email(
    email: str,
    redirect_to: str,
    *,
    organization_name: str,
) -> dict[str, Any]:
    response = _run_admin_operation(
        "invite_user_by_email",
        lambda client: client.auth.admin.invite_user_by_email(
            email,
            options={
                "redirect_to": redirect_to,
                "data": {
                    "organization_name": organization_name.strip(),
                },
            },
        ),
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


def is_existing_auth_user_error(exc: Exception) -> bool:
    """Return True only for Supabase's duplicate Auth-user condition."""
    status = _status_code(exc)
    message = _sanitized_exception_message(exc).lower()
    return status == 422 and "already been registered" in message


def _response_value(response: Any, name: str, default: Any = None) -> Any:
    value = getattr(response, name, None)
    if value is not None:
        return value
    if isinstance(response, dict):
        if name in response:
            return response[name]
        data = response.get("data")
        if isinstance(data, dict) and name in data:
            return data[name]
    data = getattr(response, "data", None)
    if data is not None:
        value = getattr(data, name, None)
        if value is not None:
            return value
        # Supabase Python SDK versions can expose list_users() as a response
        # whose .data is the user list itself rather than {users: [...]}.
        if name == "users" and isinstance(data, list):
            return data
    return default


def _user_field(user: Any, name: str) -> Any:
    value = getattr(user, name, None)
    if value is not None:
        return value
    if isinstance(user, dict):
        return user.get(name)
    return None


def _next_user_page(response: Any, page: int, user_count: int) -> int | None:
    next_page = _response_value(response, "next_page")
    if next_page is None:
        next_page = _response_value(response, "nextPage")
    if next_page is not None:
        try:
            next_page = int(next_page)
        except (TypeError, ValueError):
            next_page = None
        if next_page and next_page > page:
            return next_page
        return None

    last_page = _response_value(response, "last_page")
    if last_page is None:
        last_page = _response_value(response, "lastPage")
    if last_page is not None:
        try:
            return page + 1 if page < int(last_page) else None
        except (TypeError, ValueError):
            pass

    total = _response_value(response, "total")
    if total is not None:
        try:
            return page + 1 if page * 1000 < int(total) else None
        except (TypeError, ValueError):
            pass

    return page + 1 if user_count >= 1000 else None


def find_user_by_email(email: str) -> dict[str, Any] | None:
    normalized_email = str(email or "").strip().lower()
    if not normalized_email:
        return None

    page = 1
    while True:
        response = _run_admin_operation(
            "list_users",
            lambda client, page=page: client.auth.admin.list_users(
                page=page,
                per_page=1000,
            ),
        )
        users = _response_value(response, "users", []) or []
        for user in users:
            value = _user_field(user, "email")
            if str(value or "").strip().lower() != normalized_email:
                continue
            user_id = _user_field(user, "id")
            confirmed = _user_field(user, "email_confirmed_at")
            user_id = str(user_id or "").strip()
            if not user_id:
                return None
            return {
                "user_id": user_id,
                "email_confirmed": confirmed is not None,
            }

        next_page = _next_user_page(response, page, len(users))
        if next_page is None:
            return None
        page = next_page
