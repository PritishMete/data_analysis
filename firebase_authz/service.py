from __future__ import annotations
import os
import threading
import time
import uuid
from typing import Any

try:
    import firebase_admin
    from firebase_admin import auth, db
except ImportError:
    firebase_admin = auth = db = None

from .schema import ACTIONS, DEFAULT_ROLES, validate_action, validate_id

PROJECT_ID = "insightflow-5a23d"
DATABASE_URL = "https://insightflow-5a23d-default-rtdb.asia-southeast1.firebasedatabase.app"
_init_lock = threading.Lock()

class AuthzError(Exception): pass
class AuthenticationRequired(AuthzError): pass
class PermissionDenied(AuthzError): pass
class BootstrapDenied(AuthzError): pass

def _config():
    project = os.environ.get("FIREBASE_PROJECT_ID")
    url = os.environ.get("FIREBASE_DATABASE_URL")
    if project != PROJECT_ID:
        raise RuntimeError("Firebase configuration is missing or has the wrong project.")
    if url != DATABASE_URL:
        raise RuntimeError("Firebase configuration is missing or has the wrong regional Realtime Database URL.")
    if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") and not os.environ.get("GOOGLE_CLOUD_PROJECT"):
        # Application Default Credentials may still be available; firebase-admin will report a
        # precise credential error. We intentionally do not invent a fallback credential.
        pass

def initialize_firebase():
    if firebase_admin is None:
        raise RuntimeError("firebase-admin is required for Firebase authorization.")
    _config()
    if firebase_admin._apps:
        return firebase_admin.get_app()
    with _init_lock:
        if firebase_admin._apps:
            return firebase_admin.get_app()
        cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if cred_path:
            cred = firebase_admin.credentials.Certificate(cred_path)
        else:
            cred = firebase_admin.credentials.ApplicationDefault()
        return firebase_admin.initialize_app(cred, {"projectId": PROJECT_ID, "databaseURL": DATABASE_URL})

def verify_id_token(id_token: str) -> dict[str, Any]:
    if not id_token:
        raise AuthenticationRequired("Firebase authentication required.")
    initialize_firebase()
    try:
        return auth.verify_id_token(id_token, check_revoked=True)
    except Exception as exc:
        raise AuthenticationRequired("Firebase authentication failed.") from exc

def _get(path: str):
    initialize_firebase()
    return db.reference(path).get()

def _user(uid: str):
    value = _get(f"users/{validate_id(uid, 'user ID')}") or {}
    if not value:
        raise PermissionDenied("User authorization record is missing.")
    if value.get("suspended") is True:
        raise PermissionDenied("User is suspended.")
    return value

def _workspace(workspace_id: str):
    workspace_id = validate_id(workspace_id, "workspace ID")
    value = _get(f"workspaces/{workspace_id}") or {}
    if not value:
        raise PermissionDenied("Workspace is not accessible.")
    return value

def _role_permissions(workspace: dict[str, Any], member: dict[str, Any]) -> set[str]:
    role_defs = workspace.get("roles") or {}
    permissions: set[str] = set()
    for role_id, enabled in (member.get("roles") or {}).items():
        validate_id(role_id, "role ID")
        if enabled:
            permissions.update((role_defs.get(role_id) or {}).get("permissions") or [])
    return {p for p in permissions if p in ACTIONS}

def _resource_grant(workspace: dict[str, Any], uid: str, resource_id: str) -> dict[str, Any]:
    resource_id = validate_id(resource_id, "resource ID")
    resource = (workspace.get("resources") or {}).get(resource_id)
    if not isinstance(resource, dict):
        raise PermissionDenied("Resource is not accessible.")
    grants = (resource.get("grants") or {}).get(uid) or {}
    return grants if isinstance(grants, dict) else {}

def authorization(uid: str, workspace_id: str, action: str, resource_id: str | None = None) -> dict[str, Any]:
    validate_id(uid, "user ID")
    validate_id(workspace_id, "workspace ID")
    validate_action(action)
    user = _user(uid)
    workspace = _workspace(workspace_id)
    members = workspace.get("members") or {}
    member = members.get(uid)
    if not isinstance(member, dict):
        raise PermissionDenied("User is not a member of this workspace.")

    permissions = _role_permissions(workspace, member)
    requires_resource = action in {"data.view", "analysis.run", "worksheet.modify", "worksheet.delete", "operation.undo.own", "operation.undo.other"}
    if requires_resource and not resource_id:
        raise PermissionDenied("A resource ID is required for this action.")

    if resource_id:
        grant = _resource_grant(workspace, uid, resource_id)
        grant_permissions = {p for p, enabled in grant.get("permissions", {}).items() if enabled and p in ACTIONS}
        permissions &= grant_permissions
        if action not in permissions:
            raise PermissionDenied("Permission denied for this resource.")

    if action not in permissions:
        raise PermissionDenied("Permission denied.")
    return {
        "allowed": True, "uid": uid, "workspace_id": workspace_id, "action": action,
        "resource_id": resource_id, "role_ids": [r for r,v in (member.get("roles") or {}).items() if v],
    }

def protected_context(id_token: str, workspace_id: str, action: str, resource_id: str | None = None):
    claims = verify_id_token(id_token)
    return claims, authorization(str(claims["uid"]), workspace_id, action, resource_id)

def bootstrap_owner(id_token: str, bootstrap_secret: str, workspace_id: str, expected_uid: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(expected_uid, "user ID")
    claims = verify_id_token(id_token)
    if claims.get("uid") != expected_uid:
        raise BootstrapDenied("Bootstrap identity mismatch.")
    expected = os.environ.get("INSIGHTFLOW_BOOTSTRAP_SECRET")
    if not expected or bootstrap_secret != expected:
        raise BootstrapDenied("Bootstrap credential rejected.")
    initialize_firebase()
    ref = db.reference(f"workspaces/{workspace_id}")
    def txn(current):
        if current is not None:
            return current
        now = int(time.time() * 1000)
        roles = {rid: {"name": rid.title(), "permissions": sorted(perms), "system": True}
                 for rid, perms in DEFAULT_ROLES.items()}
        return {
            "bootstrap": {"initialized": True, "owner_uid": expected_uid, "initialized_at": now, "nonce": uuid.uuid4().hex},
            "roles": roles,
            "members": {expected_uid: {"roles": {"owner": True}}},
            "resources": {},
        }
    result = ref.transaction(txn)
    if not isinstance(result, dict) or (result.get("bootstrap") or {}).get("owner_uid") != expected_uid:
        raise BootstrapDenied("Workspace initialization was not completed by this bootstrap request.")
    return {"initialized": True, "owner_uid": expected_uid}

def ensure_seed_roles(workspace_id: str):
    validate_id(workspace_id, "workspace ID")
    initialize_firebase()
    ref = db.reference(f"workspaces/{workspace_id}/roles")
    current = ref.get() or {}
    merged = dict(current)
    for rid, perms in DEFAULT_ROLES.items():
        merged.setdefault(rid, {"name": rid.title(), "permissions": sorted(perms), "system": True})
    ref.set(merged)

def last_owner_guard(workspace_id: str, target_uid: str):
    workspace = _workspace(workspace_id)
    members = workspace.get("members") or {}
    active_owners = [
        uid for uid, member in members.items()
        if isinstance(member, dict) and (member.get("roles") or {}).get("owner") is True
        and not ((_get(f"users/{uid}") or {}).get("suspended") is True)
    ]
    if target_uid in active_owners and len(active_owners) <= 1:
        raise PermissionDenied("The last active Owner cannot be removed or suspended.")

def mutate_role(target_uid: str, role_id: str, enabled: bool, actor_token: str, workspace_id: str):
    validate_id(target_uid, "user ID")
    validate_id(role_id, "role ID")
    claims = verify_id_token(actor_token)
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "roles.manage")
    if role_id == "owner" and not enabled:
        last_owner_guard(workspace_id, target_uid)
    db.reference(f"workspaces/{workspace_id}/members/{target_uid}/roles/{role_id}").set(bool(enabled))
    return True
