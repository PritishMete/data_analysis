"""Server-side delivery for InsightFlow employee invitations."""
from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request


logger = logging.getLogger(__name__)


class InvitationEmailConfigurationError(RuntimeError):
    """Invitation email delivery is not configured."""


class InvitationEmailDeliveryError(RuntimeError):
    """Invitation email delivery failed."""


def send_invitation_email(
    *,
    recipient: str,
    organization_name: str,
    role_id: str,
    invitation_url: str,
    expires_at: object | None,
) -> None:
    api_key = os.environ.get("RESEND_API_KEY", "").strip()
    from_email = os.environ.get("INSIGHTFLOW_INVITE_FROM_EMAIL", "").strip()
    if not api_key or not from_email:
        raise InvitationEmailConfigurationError(
            "Employee invitation email delivery is not configured. "
            "Set RESEND_API_KEY and INSIGHTFLOW_INVITE_FROM_EMAIL."
        )

    expires_text = ""
    if expires_at is not None:
        try:
            expires_text = expires_at.strftime("%B %d, %Y at %I:%M %p UTC")
        except AttributeError:
            expires_text = str(expires_at)

    organization = organization_name.strip() or "your organization"
    role = role_id.replace("_", " ").strip().title()
    html = f"""<!doctype html>
<html>
  <body style="font-family:Arial,sans-serif;line-height:1.5;color:#172033">
    <h2>You're invited to InsightFlow</h2>
    <p>You have been invited to join <strong>{organization}</strong> as <strong>{role}</strong>.</p>
    <p>No InsightFlow account is created until you accept this invitation and complete signup.</p>
    <p><a href="{invitation_url}" style="display:inline-block;padding:12px 18px;background:#1677ff;color:#fff;text-decoration:none;border-radius:8px">Accept invitation</a></p>
    <p>This invitation is one-time use and expires{(" on " + expires_text) if expires_text else " according to the invitation policy"}.</p>
    <p>If you did not expect this invitation, you can safely ignore this email.</p>
  </body>
</html>"""

    payload = json.dumps({
        "from": from_email,
        "to": [recipient],
        "subject": f"You're invited to InsightFlow - {organization}",
        "html": html,
    }).encode("utf-8")

    request = urllib.request.Request(
        "https://api.resend.com/emails",
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status < 200 or response.status >= 300:
                raise InvitationEmailDeliveryError(
                    f"Invitation email provider returned HTTP {response.status}."
                )
    except urllib.error.HTTPError as exc:
        body = exc.read(500).decode("utf-8", errors="replace")
        logger.warning(
            "invitation_email_delivery_failed status=%s provider_message=%s",
            exc.code,
            body[:500],
        )
        raise InvitationEmailDeliveryError(
            "Invitation email could not be delivered."
        ) from exc
    except urllib.error.URLError as exc:
        raise InvitationEmailDeliveryError(
            "Invitation email provider could not be reached."
        ) from exc
