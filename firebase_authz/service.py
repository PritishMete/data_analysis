from __future__ import annotations
import os, threading, time, uuid
from typing import Any

try:
    import firebase_admin
    from firebase_admin import auth, db
except ImportError:  # tested through dependency/import boundary
    firebase_admin = auth = db = None

from .schema import ACTIONS, DEFAULT_ROLES, clean_permissions

_init_lock = threading.Lock()

class AuthzError(Exception): pass
class AuthenticationRequired(AuthzError): pass
class PermissionDenied(AuthzError): pass
class BootstrapDenied(AuthzError): pass


def initialize_firebase():
    if firebase_admin is None:
        raise RuntimeError("firebase-admin is required for Firebase authorization.")
    if firebase_admin._apps:
        return firebase_admin.get_app()
    with _init_lock:
        if firebase_admin._apps:
            return firebase_admin.get_app()
        options = {"databaseURL": os.environ.get("FIREBASE_DATABASE_URL", "https://insightflow-5a23d-default-rtdb.firebaseio.com")}
        cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if cred_path:
            cred = firebase_admin.credentials.Certificate(cred_path)
        else:
            cred = firebase_admin.credentials.ApplicationDefault()
        return firebase_admin.initialize_app(cred, options)


def verify_id_token(id_token: str) -> dict[str, Any]:
    if not id_token: raise AuthenticationRequired("Firebase ID token is required.")
    initialize_firebase()
    try: return auth.verify_id_token(id_token, check_revoked=True)
    except Exception as exc: raise AuthenticationRequired("Authentication failed.") from exc


def _root():
    initialize_firebase()
    return db.reference("/")


def _get(path: str): return _root().child(path).get()


def _user(uid: str):
    value = _get(f"users/{uid}") or {}
    if not value: raise PermissionDenied("User authorization record is missing.")
    if value.get("suspended") is True: raise PermissionDenied("User is suspended.")
    return value


def authorization(uid: str, workspace_id: str, action: str, resource_id: str | None = None) -> dict[str, Any]:
    if action not in ACTIONS: raise PermissionDenied("Unknown protected action.")
    user = _user(uid)
    roles = user.get("roles") or {}
    permissions: set[str] = set()
    role_defs = _get("roles") or {}
    for role_id, enabled in roles.items():
        if enabled:
            permissions.update((role_defs.get(role_id) or {}).get("permissions") or [])
    grants = ((_get(f"workspaces/{workspace_id}/grants/{uid}") or {}).get("permissions") or {})
    permissions.update(p for p, enabled in grants.items() if enabled)
    allowed = action in permissions
    if not allowed: raise PermissionDenied(f"Permission denied for action '{action}'.")
    return {"allowed": True, "uid": uid, "workspace_id": workspace_id, "action": action, "role_ids": [r for r,v in roles.items() if v], "resource_id": resource_id}


def protected_context(id_token: str, workspace_id: str, action: str, resource_id: str | None = None):
    claims = verify_id_token(id_token)
    uid = str(claims["uid"])
    decision = authorization(uid, workspace_id, action, resource_id)
    return claims, decision


def bootstrap_owner(id_token: str, bootstrap_secret: str, workspace_id: str, expected_uid: str):
    """First-owner bootstrap. Firebase auth is necessary but never sufficient.
    A separately provisioned bootstrap secret is required and the RTDB transaction
    only succeeds when the workspace is still uninitialized.
    """
    claims = verify_id_token(id_token)
    if claims["uid"] != expected_uid: raise BootstrapDenied("Bootstrap identity mismatch.")
    expected = os.environ.get("INSIGHTFLOW_BOOTSTRAP_SECRET")
    if not expected or bootstrap_secret != expected: raise BootstrapDenied("Invalid bootstrap credential.")
    initialize_firebase()
    ref = db.reference(f"workspaces/{workspace_id}/bootstrap")
    def txn(current):
        if current is not None: return current
        return {"initialized": True, "owner_uid": expected_uid, "initialized_at": int(time.time()*1000), "nonce": str(uuid.uuid4())}
    result = ref.transaction(txn)
    if result.get("owner_uid") != expected_uid: raise BootstrapDenied("Workspace was initialized by another bootstrap transaction.")
    # Owner assignment is a second transaction guarded by the same bootstrap identity.
    user_ref = db.reference(f"users/{expected_uid}/roles/owner")
    user_ref.set(True)
    return {"initialized": True, "owner_uid": expected_uid}


def ensure_seed_roles():
    initialize_firebase()
    roles_ref = db.reference("roles")
    current = roles_ref.get() or {}
    merged = dict(current)
    for rid, perms in DEFAULT_ROLES.items():
        merged.setdefault(rid, {"name": rid.title(), "permissions": sorted(perms), "system": True})
    roles_ref.set(merged)


def last_owner_guard(uid: str):
    users = _get("users") or {}
    count = 0
    for record in users.values():
        if record.get("suspended") is not True and (record.get("roles") or {}).get("owner") is True:
            count += 1
    if count <= 1 and ((_user(uid).get("roles") or {}).get("owner") is True):
        raise PermissionDenied("The last active Owner cannot be removed or suspended.")


def mutate_role(target_uid: str, role_id: str, enabled: bool, actor_token: str):
    claims = verify_id_token(actor_token); actor = str(claims["uid"])
    authorization(actor, "__admin__", "roles.manage")
    if role_id == "owner" and not enabled: last_owner_guard(target_uid)
    db.reference(f"users/{target_uid}/roles/{role_id}").set(bool(enabled))
    return True
