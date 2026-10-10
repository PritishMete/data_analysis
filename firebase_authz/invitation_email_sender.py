"""Explicit server-side adapter for branch-scoped Gmail invitation delivery."""
from __future__ import annotations

import os
from typing import Any


class InvitationEmailSenderNotConfigured(RuntimeError):
    """Raised when the production sender has not been wired to this adapter."""


def send_invitation_email(
    *, email: str, invitation_url: str, organization_name: str, role_id: str,
    workspace_id: str, location_id: str,
) -> Any:
    required = ("INSIGHTFLOW_GMAIL_CLIENT_ID", "INSIGHTFLOW_GMAIL_CLIENT_SECRET",
                "INSIGHTFLOW_GMAIL_REDIRECT_URI", "INSIGHTFLOW_GMAIL_STATE_SECRET",
                "INSIGHTFLOW_GMAIL_TOKEN_ENCRYPTION_KEY")
    if any(not os.environ.get(name, "").strip() for name in required):
        raise InvitationEmailSenderNotConfigured(
            "The branch Gmail sender is not configured on the backend."
        )
    from .gmail_invitation_email import GmailConfigurationError, send_invitation_email as send_via_gmail
    try:
        return send_via_gmail(email=email, invitation_url=invitation_url,
            organization_name=organization_name, role_id=role_id,
            workspace_id=workspace_id, location_id=location_id)
    except GmailConfigurationError as exc:
        raise InvitationEmailSenderNotConfigured(
            "The branch Gmail sender is not configured or authorized."
        ) from exc
