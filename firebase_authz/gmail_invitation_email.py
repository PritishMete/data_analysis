"""Branch-scoped Gmail OAuth and API delivery for InsightFlow invitations."""
from __future__ import annotations
import base64, hashlib, hmac, html, json, os, secrets, time, urllib.error, urllib.parse, urllib.request
from email.message import EmailMessage
from email.utils import formataddr
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import text
from core.db import SessionLocal
from .service import AuthzError

GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.settings.basic"
TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me"

class GmailConfigurationError(RuntimeError): pass
class GmailConnectionError(RuntimeError): pass

def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value: raise GmailConfigurationError(f"{name} is not configured on the backend.")
    return value

def _fernet() -> Fernet:
    try: return Fernet(_required("INSIGHTFLOW_GMAIL_TOKEN_ENCRYPTION_KEY").encode())
    except (ValueError, TypeError) as exc:
        raise GmailConfigurationError("The Gmail token encryption key is invalid.") from exc

def _encode_state(payload: dict) -> str:
    encoded=base64.urlsafe_b64encode(json.dumps(payload,separators=(",",":"),sort_keys=True).encode()).decode().rstrip("=")
    sig=hmac.new(_required("INSIGHTFLOW_GMAIL_STATE_SECRET").encode(),encoded.encode(),hashlib.sha256).hexdigest()
    return f"{encoded}.{sig}"

def _decode_state(state: str) -> dict:
    try:
        encoded,sig=str(state or "").split(".",1)
        expected=hmac.new(_required("INSIGHTFLOW_GMAIL_STATE_SECRET").encode(),encoded.encode(),hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig,expected): raise ValueError
        payload=json.loads(base64.urlsafe_b64decode(encoded+"="*((4-len(encoded)%4)%4)))
        if int(payload["exp"])<int(time.time()) or not payload.get("nonce"): raise ValueError
        if any(not str(payload.get(k) or "").strip() for k in ("workspace_id","location_id","principal_id")): raise ValueError
        return payload
    except (ValueError,KeyError,TypeError,json.JSONDecodeError) as exc:
        raise GmailConnectionError("Gmail connection state is invalid or expired.") from exc

def _actor_for_location(workspace_id: str, location_id: str, principal_id: str) -> None:
    with SessionLocal() as db:
        member=db.execute(text("""SELECT 1 FROM organization_members WHERE principal_id=:p
          AND organization_id=:o AND workspace_id=:o AND status='active'"""),{"p":principal_id,"o":workspace_id}).scalar_one_or_none()
        if not member: raise AuthzError("Workspace authorization denied.")
        roles=set(db.execute(text("""SELECT role_id FROM member_roles WHERE organization_id=:o AND principal_id=:p"""),
          {"o":workspace_id,"p":principal_id}).scalars().all())
        if "organization_owner" in roles: return
        branch_head=db.execute(text("""SELECT 1 FROM organizational_assignments WHERE organization_id=:o
          AND principal_id=:p AND location_id=:l AND role_id='branch_head' AND status='active'"""),
          {"o":workspace_id,"p":principal_id,"l":location_id}).scalar_one_or_none()
        if not branch_head: raise AuthzError("Only the Branch Head can configure the branch sender.")

def gmail_connection_url(workspace_id: str, location_id: str, principal_id: str) -> str:
    _actor_for_location(workspace_id,location_id,principal_id)
    state=_encode_state({"workspace_id":workspace_id,"location_id":location_id,"principal_id":principal_id,
      "exp":int(time.time())+600,"nonce":secrets.token_urlsafe(24)})
    params=urllib.parse.urlencode({"client_id":_required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
      "redirect_uri":_required("INSIGHTFLOW_GMAIL_REDIRECT_URI"),"response_type":"code","scope":GMAIL_SCOPE,
      "access_type":"offline","prompt":"consent","include_granted_scopes":"true","state":state})
    return "https://accounts.google.com/o/oauth2/v2/auth?"+params

def _http_json(url: str, method: str="GET", data: bytes|None=None, headers: dict|None=None) -> dict:
    request=urllib.request.Request(url,data=data,method=method,headers=headers or {})
    try:
        with urllib.request.urlopen(request,timeout=15) as response:
            raw=response.read()
            return json.loads(raw.decode()) if raw else {}
    except (urllib.error.HTTPError,urllib.error.URLError,TimeoutError,json.JSONDecodeError,UnicodeDecodeError) as exc:
        # Do not include provider response bodies, OAuth codes, URLs, or tokens in errors/logs.
        raise GmailConnectionError("Google OAuth or Gmail API request failed.") from exc

def _post_form(url: str, data: dict) -> dict:
    return _http_json(url,"POST",urllib.parse.urlencode(data).encode(),
      {"Content-Type":"application/x-www-form-urlencoded","Accept":"application/json"})

def _gmail_json(url: str, access_token: str, body: dict|None=None) -> dict:
    data=None if body is None else json.dumps(body).encode()
    headers={"Authorization":f"Bearer {access_token}","Accept":"application/json"}
    if body is not None: headers["Content-Type"]="application/json"
    return _http_json(url,"POST" if body is not None else "GET",data,headers)

def complete_gmail_connection(code: str, state: str) -> dict:
    if not str(code or "").strip(): raise GmailConnectionError("Google did not return an authorization code.")
    payload=_decode_state(state)
    _actor_for_location(payload["workspace_id"],payload["location_id"],payload["principal_id"])
    tokens=_post_form(TOKEN_URL,{"code":code,"client_id":_required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
      "client_secret":_required("INSIGHTFLOW_GMAIL_CLIENT_SECRET"),"redirect_uri":_required("INSIGHTFLOW_GMAIL_REDIRECT_URI"),
      "grant_type":"authorization_code"})
    refresh,access=tokens.get("refresh_token"),tokens.get("access_token")
    if not refresh or not access: raise GmailConnectionError("Google did not return an offline refresh token. Reconnect Gmail.")
    send_as=_gmail_json(f"{GMAIL_API}/settings/sendAs",access).get("sendAs",[])
    primary=next((item for item in send_as if isinstance(item,dict) and item.get("isPrimary")),None)
    account=str((primary or {}).get("sendAsEmail") or "").strip().lower()
    if "@" not in account: raise GmailConnectionError("Google did not return a verified primary Gmail sender address.")
    encrypted=_fernet().encrypt(refresh.encode()).decode()
    with SessionLocal.begin() as db:
        valid=db.execute(text("""SELECT 1 FROM locations WHERE organization_id=:o AND location_id=:l AND status='active'"""),
          {"o":payload["workspace_id"],"l":payload["location_id"]}).scalar_one_or_none()
        if not valid: raise AuthzError("Workspace authorization denied.")
        db.execute(text("""INSERT INTO branch_email_settings
          (organization_id,location_id,sender_name,sender_email,gmail_refresh_token_encrypted,gmail_google_subject,sender_identity,updated_at)
          VALUES (:o,:l,'InsightFlow',:e,:t,:s,:e,now())
          ON CONFLICT (organization_id,location_id) DO UPDATE SET sender_email=excluded.sender_email,
          gmail_refresh_token_encrypted=excluded.gmail_refresh_token_encrypted,
          gmail_google_subject=excluded.gmail_google_subject,sender_identity=excluded.sender_identity,updated_at=now()"""),
          {"o":payload["workspace_id"],"l":payload["location_id"],"e":account,"t":encrypted,"s":account})
    return {"connected":True,"sender_email":account,"sender_identity":account}

def _connection(workspace_id: str, location_id: str) -> tuple[dict,str]:
    with SessionLocal() as db:
        row=db.execute(text("""SELECT o.name AS organization_name,l.name AS branch_name,bes.sender_name,
          bes.sender_email,bes.sender_identity,bes.gmail_refresh_token_encrypted
          FROM organizations o JOIN locations l ON l.organization_id=o.organization_id
          JOIN branch_email_settings bes ON bes.organization_id=o.organization_id AND bes.location_id=l.location_id
          WHERE o.organization_id=:o AND l.location_id=:l AND o.status='active' AND l.status='active'"""),
          {"o":workspace_id,"l":location_id}).mappings().first()
    if not row or not row["gmail_refresh_token_encrypted"]:
        raise GmailConfigurationError("Connect a Gmail account for this branch before sending invitations.")
    try: refresh=_fernet().decrypt(str(row["gmail_refresh_token_encrypted"]).encode()).decode()
    except InvalidToken as exc: raise GmailConfigurationError("Stored Gmail authorization is invalid. Reconnect the branch account.") from exc
    return dict(row),refresh

def _refresh_access_token(refresh_token: str) -> str:
    result=_post_form(TOKEN_URL,{"client_id":_required("INSIGHTFLOW_GMAIL_CLIENT_ID"),
      "client_secret":_required("INSIGHTFLOW_GMAIL_CLIENT_SECRET"),"refresh_token":refresh_token,"grant_type":"refresh_token"})
    if not result.get("access_token"):
        raise GmailConnectionError("Gmail authorization expired or was revoked. Reconnect the branch account.")
    return str(result["access_token"])

def _authorized_sender(access_token: str, requested: str, primary: str) -> str:
    aliases=_gmail_json(f"{GMAIL_API}/settings/sendAs",access_token).get("sendAs",[])
    for item in aliases if isinstance(aliases,list) else []:
        address=str(item.get("sendAsEmail") or "").strip().lower()
        verified=bool(item.get("isPrimary")) or str(item.get("verificationStatus") or "").lower()=="accepted"
        if address==requested and verified: return address
    raise GmailConfigurationError("The configured sender address is not a verified Gmail sender for the connected account.")

def send_invitation_email(*, email: str, invitation_url: str, organization_name: str, role_id: str,
                          workspace_id: str, location_id: str) -> None:
    recipient=str(email or "").strip()
    if not recipient or len(recipient)>320 or "@" not in recipient: raise ValueError("Invitation recipient email is invalid.")
    settings,refresh=_connection(workspace_id,location_id)
    access=_refresh_access_token(refresh)
    primary=str(settings["sender_email"]).strip().lower()
    requested=str(settings.get("sender_identity") or primary).strip().lower()
    sender=_authorized_sender(access,requested,primary)
    company=str(settings["organization_name"]).strip()
    branch=str(settings["branch_name"]).strip()
    brand=" · ".join(x for x in ("InsightFlow",company,branch) if x)[:120]
    role=str(role_id or "").replace("_"," ").strip().title()
    msg=EmailMessage()
    msg["To"]=recipient
    msg["From"]=formataddr((brand,sender))
    msg["Subject"]=f"You're invited to InsightFlow - {company}"
    msg.set_content(f"You have been invited to join {company} ({branch}) as {role}.\n\nAccept invitation: {invitation_url}\n\nNo account is created until you accept.")
    msg.add_alternative(f'<!doctype html><html><body><h2>You\'re invited to InsightFlow</h2><p>You have been invited to join <strong>{html.escape(company)}</strong> as <strong>{html.escape(role)}</strong>.</p><p><a href="{html.escape(invitation_url,quote=True)}">Accept invitation</a></p><p>This invitation is single-use.</p></body></html>',subtype="html")
    raw=base64.urlsafe_b64encode(msg.as_bytes()).decode().rstrip("=")
    result=_gmail_json(f"{GMAIL_API}/messages/send",access,{"raw":raw})
    if not result.get("id"): raise GmailConnectionError("Gmail API did not confirm acceptance of the invitation message.")
