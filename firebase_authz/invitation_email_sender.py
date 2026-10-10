"""Explicit server-side adapter for application invitation email delivery.

The active production sender must be configured as a server-side callable:
INSIGHTFLOW_INVITATION_EMAIL_SENDER=package.module:callable

The callable receives keyword arguments email, invitation_url, organization_name,
and role_id. No fallback provider is selected: absent configuration fails closed
so we never send a Supabase Auth link that cannot redeem an application token.
"""
from __future__ import annotations

import importlib
import os
from typing import Any


class InvitationEmailSenderNotConfigured(RuntimeError):
    """Raised when the production sender has not been wired to this adapter."""


def send_invitation_email(
    *, email: str, invitation_url: str, organization_name: str, role_id: str
) -> Any:
    target = os.environ.get("INSIGHTFLOW_INVITATION_EMAIL_SENDER", "").strip()
    if not target or ":" not in target:
        raise InvitationEmailSenderNotConfigured(
            "INSIGHTFLOW_INVITATION_EMAIL_SENDER must identify the existing production sender callable."
        )
    module_name, function_name = target.rsplit(":", 1)
    if not module_name or not function_name:
        raise InvitationEmailSenderNotConfigured(
            "INSIGHTFLOW_INVITATION_EMAIL_SENDER must use module:callable syntax."
        )
    sender = getattr(importlib.import_module(module_name), function_name, None)
    if not callable(sender):
        raise InvitationEmailSenderNotConfigured(
            "Configured invitation sender callable could not be resolved."
        )
    return sender(
        email=email,
        invitation_url=invitation_url,
        organization_name=organization_name,
        role_id=role_id,
    )
