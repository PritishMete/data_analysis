from __future__ import annotations
import os, threading, time, uuid
from typing import Any
try:
    import firebase_admin
    from firebase_admin import auth, db
except ImportError:
    firebase_admin = auth = db = None
from .schema import ACTIONS, DEFAULT_ROLES

_init_lock = threading.Lock()

class AuthzError(Exception): pass
class AuthenticationRequired(AuthzError): pass
class PermissionDenied(AuthzError): pass
class BootstrapDenied(AuthzError): pass

def initialize_firebase():
    if firebase_admin is None:
        raise RuntimeError("firebase-admin is required for Firebase authorization.")
    if firebase_admin._apps: return firebase_admin.get_app()
    with _init_lock:
        if firebase_admin._apps: return firebase_admin.get_app()
        options={"databaseURL":os.environ.get("FIREBASE_DATABASE_URL","https://insightflow-5a23d-default-rtdb.firebaseio.com")}
        cred_path=os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        cred=firebase_admin.credentials.Certificate(cred_path) if cred_path else firebase_admin.credentials.ApplicationDefault()
        return firebase_admin.initialize_app(cred,options)

def verify_id_token(id_token:str)->dict[str,Any]:
    if not id_token: raise AuthenticationRequired("Firebase ID token is required.")
    initialize_firebase()
    try: return auth.verify_id_token(id_token,check_revoked=True)
    except Exception as exc: raise AuthenticationRequired("Authentication failed.") from exc

def _get(path:str):
    initialize_firebase()
    return db.reference(path).get()

def _user(uid:str):
    value=_get(f"users/{uid}") or {}
    if not value: raise PermissionDenied("User authorization record is missing.")
    if value.get("suspended") is True: raise PermissionDenied("User is suspended.")
    return value

def _role_permissions(user:dict[str,Any])->set[str]:
    roles=user.get("roles") or {}
    defs=_get("roles") or {}
    permissions=set()
    for role_id,enabled in roles.items():
        if enabled: permissions.update((defs.get(role_id) or {}).get("permissions") or [])
    return permissions

def authorization(uid:str,workspace_id:str,action:str,resource_id:str|None=None)->dict[str,Any]:
    if action not in ACTIONS: raise PermissionDenied("Unknown protected action.")
    user=_user(uid)
    permissions=_role_permissions(user)
    workspace=_get(f"workspaces/{workspace_id}") or {}
    bootstrap=workspace.get("bootstrap") or {}
    is_workspace_owner=bootstrap.get("owner_uid")==uid
    if is_workspace_owner:
        permissions.update(DEFAULT_ROLES["owner"])
    else:
        member=bool((workspace.get("members") or {}).get(uid))
        grant=((workspace.get("grants") or {}).get(uid) or {}).get("permissions") or {}
        if not member: raise PermissionDenied("User is not a member of this workspace.")
        permissions.update(p for p,enabled in grant.items() if enabled)
    if action not in permissions: raise PermissionDenied(f"Permission denied for action '{action}'.")
    return {"allowed":True,"uid":uid,"workspace_id":workspace_id,"action":action,"role_ids":[r for r,v in (user.get("roles") or {}).items() if v],"resource_id":resource_id}

def protected_context(id_token:str,workspace_id:str,action:str,resource_id:str|None=None):
    claims=verify_id_token(id_token)
    return claims,authorization(str(claims["uid"]),workspace_id,action,resource_id)

def bootstrap_owner(id_token:str,bootstrap_secret:str,workspace_id:str,expected_uid:str):
    claims=verify_id_token(id_token)
    if claims["uid"]!=expected_uid: raise BootstrapDenied("Bootstrap identity mismatch.")
    expected=os.environ.get("INSIGHTFLOW_BOOTSTRAP_SECRET")
    if not expected or bootstrap_secret!=expected: raise BootstrapDenied("Invalid bootstrap credential.")
    initialize_firebase()
    ref=db.reference(f"workspaces/{workspace_id}/bootstrap")
    def txn(current):
        if current is not None: return current
        return {"initialized":True,"owner_uid":expected_uid,"initialized_at":int(time.time()*1000),"nonce":str(uuid.uuid4())}
    result=ref.transaction(txn)
    if not result or result.get("owner_uid")!=expected_uid: raise BootstrapDenied("Workspace initialization lost the race.")
    # Membership is deliberately written after the atomic bootstrap transaction.
    # Owner authorization derives from bootstrap.owner_uid, so a crash here cannot
    # grant ownership to another identity.
    db.reference(f"workspaces/{workspace_id}/members/{expected_uid}").set(True)
    return {"initialized":True,"owner_uid":expected_uid}

def ensure_seed_roles():
    initialize_firebase()
    ref=db.reference("roles")
    current=ref.get() or {}
    merged=dict(current)
    for rid,perms in DEFAULT_ROLES.items():
        merged.setdefault(rid,{"name":rid.title(),"permissions":sorted(perms),"system":True})
    ref.set(merged)

def last_owner_guard(workspace_id:str,target_uid:str):
    workspace=_get(f"workspaces/{workspace_id}") or {}
    owner_uid=(workspace.get("bootstrap") or {}).get("owner_uid")
    if owner_uid==target_uid: raise PermissionDenied("The workspace Owner cannot be removed; transfer ownership first.")

def mutate_role(target_uid:str,role_id:str,enabled:bool,actor_token:str,workspace_id:str):
    claims=verify_id_token(actor_token); actor=str(claims["uid"])
    authorization(actor,workspace_id,"roles.manage")
    if role_id=="owner" and not enabled: last_owner_guard(workspace_id,target_uid)
    db.reference(f"users/{target_uid}/roles/{role_id}").set(bool(enabled))
    return True
