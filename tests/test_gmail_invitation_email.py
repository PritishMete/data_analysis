import base64
import email
from email import policy
import pytest
from cryptography.fernet import Fernet
from firebase_authz import gmail_invitation_email as gmail

def setup_env(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_GMAIL_CLIENT_ID","test-client")
    monkeypatch.setenv("INSIGHTFLOW_GMAIL_CLIENT_SECRET","test-secret")
    monkeypatch.setenv("INSIGHTFLOW_GMAIL_REDIRECT_URI","https://backend.invalid/callback")
    monkeypatch.setenv("INSIGHTFLOW_GMAIL_STATE_SECRET","test-state-secret")
    monkeypatch.setenv("INSIGHTFLOW_GMAIL_TOKEN_ENCRYPTION_KEY",Fernet.generate_key().decode())

def test_oauth_state_signature_expiry_and_scope(monkeypatch):
    setup_env(monkeypatch)
    payload={"workspace_id":"org-a","location_id":"loc-a","principal_id":"p-a","exp":4_000_000_000,"nonce":"n"}
    state=gmail._encode_state(payload)
    assert gmail._decode_state(state)["location_id"]=="loc-a"
    with pytest.raises(gmail.GmailConnectionError): gmail._decode_state(state+"tampered")
    with pytest.raises(gmail.GmailConnectionError): gmail._decode_state("bad-state")

def test_callback_rejects_missing_code(monkeypatch):
    setup_env(monkeypatch)
    with pytest.raises(gmail.GmailConnectionError,match="authorization code"):
        gmail.complete_gmail_connection("","bad-state")

def test_refresh_uses_server_side_credentials(monkeypatch):
    setup_env(monkeypatch)
    monkeypatch.setattr(gmail,"_post_form",lambda url,data:{"access_token":"test-access"})
    assert gmail._refresh_access_token("test-refresh")=="test-access"

def test_sender_address_must_be_primary_or_verified_alias(monkeypatch):
    monkeypatch.setattr(gmail,"_gmail_json",lambda *args:{"sendAs":[
      {"sendAsEmail":"owner@gmail.com","isPrimary":True,"verificationStatus":"accepted"},
      {"sendAsEmail":"alias@example.com","isPrimary":False,"verificationStatus":"pending"}]})
    assert gmail._authorized_sender("access","owner@gmail.com","owner@gmail.com")=="owner@gmail.com"
    with pytest.raises(gmail.GmailConfigurationError):
        gmail._authorized_sender("access","alias@example.com","owner@gmail.com")

def test_gmail_mime_payload_and_confirmed_message_id(monkeypatch):
    setup_env(monkeypatch)
    monkeypatch.setattr(gmail,"_connection",lambda *args:({"organization_name":"Org","branch_name":"Kolkata",
      "sender_email":"owner@gmail.com","sender_identity":"owner@gmail.com"},"refresh-token"))
    monkeypatch.setattr(gmail,"_refresh_access_token",lambda token:"access-token")
    monkeypatch.setattr(gmail,"_authorized_sender",lambda *args:"owner@gmail.com")
    captured={}
    def send(url,access,body=None):
        captured.update(url=url,body=body)
        return {"id":"accepted-message"}
    monkeypatch.setattr(gmail,"_gmail_json",send)
    gmail.send_invitation_email(email="employee@example.com",invitation_url="https://app.invalid/invite?token=opaque",
      organization_name="client-supplied-ignored",role_id="data_analyst",workspace_id="org-a",location_id="loc-a")
    assert captured["url"].endswith("/messages/send")
    raw=base64.urlsafe_b64decode(captured["body"]["raw"]+"===")
    msg=email.message_from_bytes(raw,policy=policy.default)
    assert msg["To"]=="employee@example.com" and "Org" in msg["From"]
    assert "Resend" not in captured["url"]
    assert "opaque" in msg.get_body(preferencelist=("plain",)).get_content()

def test_gmail_api_failure_is_sanitized(monkeypatch):
    monkeypatch.setattr(gmail,"_http_json",lambda *a,**k:(_ for _ in ()).throw(gmail.GmailConnectionError("failed")))
    with pytest.raises(gmail.GmailConnectionError): gmail._gmail_json("https://gmail.invalid/send","token",{"raw":"x"})

def test_oauth_callback_encrypts_refresh_token_and_binds_branch(monkeypatch):
    setup_env(monkeypatch)
    payload={"workspace_id":"org-1","location_id":"loc-9","principal_id":"principal-2",
             "exp":4_000_000_000,"nonce":"random-state"}
    state=gmail._encode_state(payload)
    actor=[]
    monkeypatch.setattr(gmail,"_actor_for_location",lambda *args:actor.append(args))
    monkeypatch.setattr(gmail,"_post_form",lambda url,data:{"access_token":"access","refresh_token":"refresh-secret"})
    monkeypatch.setattr(gmail,"_gmail_json",lambda *args:{"emailAddress":"branch-head@gmail.com"})
    captured={}
    class Context:
        def __enter__(self): return self
        def __exit__(self,*args): return False
        def execute(self,statement,params=None):
            captured["sql"]=str(statement)
            captured["params"]=dict(params or {})
            class Result:
                def scalar_one_or_none(self): return 1
            return Result()
    class Factory:
        def begin(self): return Context()
    monkeypatch.setattr(gmail,"SessionLocal",Factory())
    result=gmail.complete_gmail_connection("one-time-code",state)
    assert result["connected"] is True
    assert actor==[("org-1","loc-9","principal-2")]
    assert captured["params"]["o"]=="org-1" and captured["params"]["l"]=="loc-9"
    encrypted=captured["params"]["t"]
    assert encrypted!="refresh-secret"
    assert gmail._fernet().decrypt(encrypted.encode()).decode()=="refresh-secret"

def test_connection_refuses_unconfigured_or_wrong_branch(monkeypatch):
    setup_env(monkeypatch)
    class Result:
        def mappings(self): return self
        def first(self): return None
    class DB:
        def __enter__(self): return self
        def __exit__(self,*args): return False
        def execute(self,statement,params=None):
            self.params=dict(params or {})
            self.sql=str(statement)
            return Result()
    db=DB()
    monkeypatch.setattr(gmail,"SessionLocal",lambda:db)
    with pytest.raises(gmail.GmailConfigurationError,match="Connect a Gmail account"):
        gmail._connection("org-a","loc-b")
    assert db.params=={"o":"org-a","l":"loc-b"}
    assert "o.organization_id=:o" in db.sql and "l.location_id=:l" in db.sql

def test_gmail_api_without_message_id_is_not_success(monkeypatch):
    setup_env(monkeypatch)
    monkeypatch.setattr(gmail,"_connection",lambda *args:({"organization_name":"Org","branch_name":"Branch",
      "sender_email":"owner@gmail.com","sender_identity":"owner@gmail.com"},"refresh"))
    monkeypatch.setattr(gmail,"_refresh_access_token",lambda token:"access")
    monkeypatch.setattr(gmail,"_authorized_sender",lambda *args:"owner@gmail.com")
    monkeypatch.setattr(gmail,"_gmail_json",lambda *args:{})
    with pytest.raises(gmail.GmailConnectionError,match="did not confirm acceptance"):
        gmail.send_invitation_email(email="person@example.com",invitation_url="https://app.invalid/invite",
          organization_name="ignored",role_id="analyst",workspace_id="org-a",location_id="loc-a")
