"""Server-side Gmail OAuth and invitation delivery."""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import text

from core.db import SessionLocal
from .service import AuthzError

GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.send"


class GmailConfigurationError(RuntimeError):
    pass


class GmailConnectionError(RuntimeError):
    pass


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise GmailConfigurationError(f"{name} is not configured.")
    return value


def _fernet() -> Fernet:
    try:
        return Fernet(_required("INSIGHTFLOW_GMAIL_TOKEN_ENCRYPTION_KEY").encode())
    except (ValueError, TypeError) as exc:
        raise GmailConfigurationError(
            "INSIGHTFLOW_GMAIL_TOKEN_ENCRYPTION_KEY must be a valid Fernet key."
        ) from exc


def _state_secret() -> bytes:
    return _required("INSIGHTFLOW_GMAIL_STATE_SECRET").encode()


def _encode_state(payload: dict) -> str:
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    encoded = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    signature = hmac.new(_state_secret(), encoded.encode(), hashlib.sha256).hexdigest()
    return f"{encoded}.{signature}"


def _decode_state(state: str) -> dict:
    try:
        encoded, signature = state.split(".", 1)
        expected = hmac.new(_state_secret(), encoded.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise ValueError
        padded = encoded + "=" * ((4 - len(encoded) % 4) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        if int(payload["exp"]) < int(time.time()):
            raise ValueError
        return payload
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        raise GmailConnectionError("Gmail connection state is invalid or expired.")


def _actor_for_location(workspace_id: str, location_id: str, principal_id: str) -> None:
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT m.status FROM organization_members m
            WHERE m.principal_id=:principal AND m.organization_id=:org
              AND m.workspace_id=:workspace AND m.status='active'
        """), {"principal": principal_id, "org": workspace_id, "workspace": workspace_id}).first()
        if not row:
            raise AuthzError("Workspace authorization denied.")
        roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": principal_id}).scalars().all())
        if "organization_owner" in roles:
            return
        scoped = db.execute(text("""
            SELECT 1 FROM organizational_assignments
            WHERE organization_id=:org AND principal_id=:principal
              AND location_id=:location AND role_id='branch_head' AND status='active'
        """), {"org": workspace_id, "principal": principal_id, "location": location_id}).scalar_one_or_none()
        if not scoped:
            raise AuthzError("Only the Branch Head can configure the branch sender.")


def gmail_connection_url(workspace_id: str, location_id: str, principal_id: str) -> str:
    _actor_for_location(workspace_id, location_id, principal_id)
    state = _encode_state({
        "workspace_id": workspace_id,
        "location_id": location_id,
        "principal_id": principal_id,
        "exp": int(time.time()) + 600,
        "nonce": secrets.token_urlsafe(12),
    })
    params = urllib.parse.urlencode({
        "client_id": _required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
        "redirect_uri": _required("INSIGHTFLOW_GMAIL_REDIRECT_URI"),
        "response_type": "code",
        "scope": GMAIL_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "true",
        "state": state,
    })
    return "https://accounts.google.com/o/oauth2/v2/auth?" + params


def _post_form(url: str, data: dict) -> dict:
    request = urllib.request.Request(
        url, data=urllib.parse.urlencode(data).encode(), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise GmailConnectionError("Google authorization could not be completed.") from exc


def _gmail_json(url: str, access_token: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url, data=data, method="POST" if body is not None else "GET", headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise GmailConnectionError("Gmail API request failed.") from exc


def complete_gmail_connection(code: str, state: str) -> dict:
    payload = _decode_state(state)
    _actor_for_location(payload["workspace_id"], payload["location_id"], payload["principal_id"])
    tokens = _post_form("https://oauth2.googleapis.com/token", {
        "code": code,
        "client_id": _required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
        "client_secret": _required("INSIGHTFLOW_GMAIL_CLIENT_SECRET"),
        "redirect_uri": _required("INSIGHTFLOW_GMAIL_REDIRECT_URI"),
        "grant_type": "authorization_code",
    })
    refresh = tokens.get("refresh_token")
    access = tokens.get("access_token")
    if not refresh or not access:
        raise GmailConnectionError(
            "Google did not return a refresh token. Reconnect Gmail and approve offline access."
        )
    profile = _gmail_json(
        "https://gmail.googleapis.com/gmail/v1/users/me/profile", access
    )
    sender_email = str(profile.get("emailAddress") or "").strip().lower()
    if not sender_email or "@" not in sender_email:
        raise GmailConnectionError("Google did not return a valid Gmail address.")
    encrypted = _fernet().encrypt(refresh.encode()).decode()
    with SessionLocal.begin() as db:
        db.execute(text("""
            INSERT INTO branch_email_settings
              (organization_id, location_id, sender_name, sender_email,
               gmail_refresh_token_encrypted, gmail_google_subject, updated_at)
            VALUES (:org, :location, 'InsightFlow', :email, :token, :subject, now())
            ON CONFLICT (organization_id, location_id) DO UPDATE SET
              sender_email=excluded.sender_email,
              gmail_refresh_token_encrypted=excluded.gmail_refresh_token_encrypted,
              gmail_google_subject=excluded.gmail_google_subject,
              updated_at=now()
        """), {
            "org": payload["workspace_id"], "location": payload["location_id"],
            "email": sender_email, "token": encrypted, "subject": sender_email,
        })
    return {"sender_email": sender_email, "connected": True}


def get_branch_email_settings(claims: dict, workspace_id: str, location_id: str) -> dict:
    principal_id = str(claims.get("uid") or claims.get("sub") or "").strip()
    _actor_for_location(workspace_id, location_id, principal_id)
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT sender_name, sender_email,
                   (gmail_refresh_token_encrypted IS NOT NULL) AS connected
            FROM branch_email_settings
            WHERE organization_id=:org AND location_id=:location
        """), {"org": workspace_id, "location": location_id}).mappings().first()
    return dict(row) if row else {
        "connected": False, "sender_name": "InsightFlow", "sender_email": None
    }


def update_branch_sender_name(claims: dict, workspace_id: str, location_id: str, sender_name: str) -> dict:
    principal_id = str(claims.get("uid") or claims.get("sub") or "").strip()
    _actor_for_location(workspace_id, location_id, principal_id)
    sender_name = str(sender_name or "").strip()
    if not sender_name or len(sender_name) > 120 or any(ord(c) < 32 or ord(c) == 127 for c in sender_name):
        raise ValueError("Sender name must be between 1 and 120 characters.")
    with SessionLocal.begin() as db:
        result = db.execute(text("""
            UPDATE branch_email_settings
            SET sender_name=:name, updated_at=now()
            WHERE organization_id=:org AND location_id=:location
              AND gmail_refresh_token_encrypted IS NOT NULL
        """), {"name": sender_name, "org": workspace_id, "location": location_id})
        if result.rowcount != 1:
            raise AuthzError("Connect a Gmail account before setting the sender name.")
    return get_branch_email_settings(claims, workspace_id, location_id)


def _connection(workspace_id: str, location_id: str) -> tuple[str, str, str]:
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT sender_name, sender_email, gmail_refresh_token_encrypted
            FROM branch_email_settings
            WHERE organization_id=:org AND location_id=:location
        """), {"org": workspace_id, "location": location_id}).mappings().first()
    if not row or not row["gmail_refresh_token_encrypted"]:
        raise GmailConfigurationError("Connect a Gmail account for this branch before sending invitations.")
    try:
        refresh = _fernet().decrypt(str(row["gmail_refresh_token_encrypted"]).encode()).decode()
    except InvalidToken as exc:
        raise GmailConfigurationError("Stored Gmail authorization is invalid. Reconnect the branch Gmail account.") from exc
    return str(row["sender_name"] or "InsightFlow"), str(row["sender_email"]), refresh


def _refresh_access_token(refresh_token: str) -> str:
    result = _post_form("https://oauth2.googleapis.com/token", {
        "client_id": _required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
        "client_secret": _required("INSIGHTFLOW_GMAIL_CLIENT_SECRET"),
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    })
    access = result.get("access_token")
    if not access:
        raise GmailConnectionError("Gmail authorization has expired or been revoked.")
    return access


def send_invitation_email(*, recipient: str, organization_name: str, role_id: str,
                          invitation_url: str, expires_at: object | None,
                          workspace_id: str, location_id: str) -> None:
    sender_name, sender_email, refresh = _connection(workspace_id, location_id)
    access = _refresh_access_token(refresh)
    expires_text = ""
    if expires_at is not None:
        try:
            expires_text = expires_at.strftime("%B %d, %Y at %I:%M %p UTC")
        except AttributeError:
            expires_text = str(expires_at)
    organization = html.escape(organization_name.strip() or "your organization")
    role = html.escape(role_id.replace("_", " ").strip().title())
    safe_url = html.escape(invitation_url, quote=True)
    message = EmailMessage()
    message["From"] = f"{sender_name} <{sender_email}>"
    message["To"] = recipient
    message["Subject"] = f"You're invited to InsightFlow - {organization_name.strip() or 'your organization'}"
    message.set_content(
        f"You have been invited to join {organization_name.strip() or 'your organization'} "
        f"as {role_id.replace('_', ' ').strip().title()}.\n\n"
        f"Accept invitation: {invitation_url}\n\n"
        "No InsightFlow account is created until you accept the invitation and complete signup."
    )
    message.add_alternative(f"""<!doctype html><html><body style="font-family:Arial,sans-serif;line-height:1.5;color:#172033">
<h2>You're invited to InsightFlow</h2>
<p>You have been invited to join <strong>{organization}</strong> as <strong>{role}</strong>.</p>
<p>No InsightFlow account is created until you accept this invitation and complete signup.</p>
<p><a href="{safe_url}" style="display:inline-block;padding:12px 18px;background:#1677ff;color:#fff;text-decoration:none;border-radius:8px">Accept invitation</a></p>
<p>This invitation is one-time use{(" and expires on " + html.escape(expires_text)) if expires_text else ""}.</p>
</body></html>""", subtype="html")
    raw = base64.urlsafe_b64encode(message.as_bytes()).decode().rstrip("=")
    _gmail_json("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", access, {"raw": raw})
