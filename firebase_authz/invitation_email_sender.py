"""Explicit server-side adapter for branch-scoped Gmail invitation delivery."""
from __future__ import annotations

from typing import Any


class InvitationEmailSenderNotConfigured(RuntimeError):
    """Raised when the production sender has not been wired to this adapter."""


def send_invitation_email(
    *, email: str, invitation_url: str, organization_name: str, role_id: str,
    workspace_id: str, location_id: str,
) -> Any:
    from .gmail_invitation_email import GmailConfigurationError, send_invitation_email as send_via_gmail
    try:
        return send_via_gmail(email=email, invitation_url=invitation_url,
            organization_name=organization_name, role_id=role_id,
            workspace_id=workspace_id, location_id=location_id)
    except GmailConfigurationError as exc:
        raise InvitationEmailSenderNotConfigured(
            "The branch Gmail sender is not configured or authorized."
        ) from exc
