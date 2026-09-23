from __future__ import annotations
import os
import threading
import time
import uuid
from typing import Any
try:
    from google.auth.credentials import AnonymousCredentials
except ImportError:
    AnonymousCredentials = None

try:
    import firebase_admin
    from firebase_admin import auth, db
except ImportError:
    firebase_admin = auth = db = None

from .schema import ACTIONS, DEFAULT_ROLES, ROLE_ALIASES, ROLE_LEVELS, validate_action, validate_id

PROJECT_ID = "insightflow-5a23d"
DATABASE_URL = "https://insightflow-5a23d-default-rtdb.asia-southeast1.firebasedatabase.app/"
_init_lock = threading.Lock()

class AuthzError(Exception): pass
class AuthenticationRequired(AuthzError): pass
class EmailVerificationRequired(AuthenticationRequired): pass
class PermissionDenied(AuthzError): pass
class BootstrapDenied(AuthzError): pass

def _config():
    project = os.environ.get("FIREBASE_PROJECT_ID")
    url = os.environ.get("FIREBASE_DATABASE_URL")
    if project != PROJECT_ID:
        raise RuntimeError("Firebase configuration is missing or has the wrong project.")
    if not url or url.rstrip("/") != DATABASE_URL.rstrip("/"):
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
        elif os.environ.get("FIREBASE_DATABASE_EMULATOR_HOST"):
            if AnonymousCredentials is None:
                raise RuntimeError("Google auth credentials are required for emulator tests.")
            cred = AnonymousCredentials()
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

def _raw_user(uid: str) -> dict[str, Any]:
    value = _get(f"users/{validate_id(uid, 'user ID')}") or {}
    return value if isinstance(value, dict) else {}

def _user(uid: str):
    value = _raw_user(uid)
    if not value:
        raise PermissionDenied("User authorization record is missing.")
    status = str(value.get("status") or "").strip().lower()
    if value.get("suspended") is True or status in {"suspended", "disabled", "removed"}:
        raise PermissionDenied("User is suspended.")
    return value

def _organization_record(workspace_id: str, workspace: dict[str, Any]) -> dict[str, Any]:
    organization = workspace.get("organization")
    if isinstance(organization, dict):
        result = dict(organization)
        result.setdefault("organization_id", workspace_id)
        result.setdefault("status", "active")
        return result
    return {
        "organization_id": workspace_id,
        "status": "active",
    }

def _membership_status(member: dict[str, Any]) -> str:
    status = str(member.get("status") or "active").strip().lower()
    return status if status in {"invited", "approved", "active", "suspended", "removed"} else "active"

def authentication_context(uid: str, workspace_id: str | None = None, email_verified: bool = False) -> dict[str, Any]:
    validate_id(uid, "user ID")
    if workspace_id:
        validate_id(workspace_id, "workspace ID")
    user = _raw_user(uid)
    if not user:
        return {
            "email_verified": bool(email_verified),
            "account_status": "pending",
            "membership_status": "none",
            "workspace_authorized": False,
            "workspaces": [],
        }
    account_status = str(user.get("status") or "").strip().lower()
    if user.get("suspended") is True or account_status in {"suspended", "disabled", "removed"}:
        account_status = "suspended"
    else:
        account_status = "active"

    memberships = workspace_memberships(uid, include_user=False)
    selected = next(
        (item for item in memberships if workspace_id and item["workspace_id"] == workspace_id),
        None,
    )
    membership_status = selected["membership_status"] if selected else "none"
    workspace_authorized = bool(
        email_verified
        and account_status == "active"
        and membership_status == "active"
    )
    return {
        "email_verified": bool(email_verified),
        "account_status": account_status,
        "membership_status": membership_status,
        "workspace_authorized": workspace_authorized,
        "workspace_id": workspace_id,
        "organization_id": (
            selected.get("organization_id") if selected else None
        ),
        "employee_id": selected.get("employee_id") if selected else None,
        "workspaces": memberships,
    }

def workspace_memberships(uid: str, include_user: bool = True) -> list[dict[str, Any]]:
    validate_id(uid, "user ID")
    if include_user:
        _user(uid)
    workspaces = _get("workspaces") or {}
    memberships: list[dict[str, Any]] = []
    for workspace_id, workspace in workspaces.items():
        if not isinstance(workspace, dict):
            continue
        member = (workspace.get("members") or {}).get(uid)
        if isinstance(member, dict):
            role_ids = [
                role_id
                for role_id, enabled in (member.get("roles") or {}).items()
                if enabled
            ]
            organization = _organization_record(workspace_id, workspace)
            memberships.append({
                "workspace_id": workspace_id,
                "organization_id": organization["organization_id"],
                "membership_status": _membership_status(member),
                "employee_id": str(member.get("employee_id") or f"emp_{uid}"),
                "role_ids": role_ids,
            })
    return memberships

def _workspace(workspace_id: str):
    workspace_id = validate_id(workspace_id, "workspace ID")
    value = _get(f"workspaces/{workspace_id}") or {}
    if not value:
        raise PermissionDenied("Workspace is not accessible.")
    return value

def _effective_role_ids(member: dict[str, Any]) -> list[str]:
    raw = [
        role_id for role_id, enabled in (member.get("roles") or {}).items()
        if enabled
    ]
    return [ROLE_ALIASES.get(role_id, role_id) for role_id in raw]

def _effective_role_level(member: dict[str, Any]) -> int:
    levels = [ROLE_LEVELS.get(role_id, 0) for role_id in _effective_role_ids(member)]
    return max(levels, default=0)

def _role_permissions(workspace: dict[str, Any], member: dict[str, Any]) -> set[str]:
    role_defs = workspace.get("roles") or {}
    permissions: set[str] = set()
    for role_id, enabled in (member.get("roles") or {}).items():
        validate_id(role_id, "role ID")
        effective_role_id = ROLE_ALIASES.get(role_id, role_id)
        if enabled:
            definition = role_defs.get(effective_role_id) or role_defs.get(role_id) or {}
            permissions.update(definition.get("permissions") or [])
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
    if resource_id is not None:
        validate_id(resource_id, "resource ID")
    requires_resource = action in {"data.view", "analysis.run", "worksheet.create", "pivot.create", "worksheet.modify", "worksheet.delete", "operation.undo.own", "operation.undo.other"}
    if requires_resource and not resource_id:
        raise PermissionDenied("A resource ID is required for this action.")
    user = _user(uid)
    workspace = _workspace(workspace_id)
    members = workspace.get("members") or {}
    member = members.get(uid)
    if not isinstance(member, dict):
        raise PermissionDenied("User is not a member of this workspace.")
    if _membership_status(member) != "active":
        raise PermissionDenied("User membership is not active.")

    permissions = _role_permissions(workspace, member)

    if resource_id:
        grant = _resource_grant(workspace, uid, resource_id)
        grant_permissions = {p for p in (grant.get("permissions") or []) if p in ACTIONS}
        permissions &= grant_permissions
        if action not in permissions:
            raise PermissionDenied("Permission denied for this resource.")

    if action not in permissions:
        raise PermissionDenied("Permission denied.")
    return {
        "allowed": True, "uid": uid, "workspace_id": workspace_id, "action": action,
        "resource_id": resource_id,
        "role_ids": _effective_role_ids(member),
    }

def can_manage_role(workspace_id: str, actor_uid: str, target_uid: str, role_id: str, enabled: bool) -> bool:
    validate_id(role_id, "role ID")
    workspace = _workspace(workspace_id)
    members = workspace.get("members") or {}
    actor = members.get(actor_uid)
    target = members.get(target_uid)
    if not isinstance(actor, dict) or not isinstance(target, dict):
        raise PermissionDenied("Both users must be organization members.")
    normalized_role = ROLE_ALIASES.get(role_id, role_id)
    target_level = ROLE_LEVELS.get(normalized_role)
    actor_level = _effective_role_level(actor)
    if target_level is None:
        raise PermissionDenied("Role is not part of the organization RBAC model.")
    if actor_uid == target_uid and enabled:
        raise PermissionDenied("A user cannot grant a higher role to themselves.")
    if target_level >= actor_level and actor_level < ROLE_LEVELS["organization_owner"]:
        raise PermissionDenied("Delegated administration cannot grant an equal or higher role.")
    if normalized_role == "organization_owner" and actor_level < ROLE_LEVELS["organization_owner"]:
        raise PermissionDenied("Only the Organization Owner can manage Owner access.")
    return True

def require_email_verified(claims: dict[str, Any]) -> dict[str, Any]:
    if claims.get("email_verified") is not True:
        raise EmailVerificationRequired("Email verification required.")
    return claims

def protected_context(id_token: str, workspace_id: str, action: str, resource_id: str | None = None):
    claims = require_email_verified(verify_id_token(id_token))
    return claims, authorization(str(claims["uid"]), workspace_id, action, resource_id)

def bootstrap_owner(id_token: str, bootstrap_secret: str, workspace_id: str, expected_uid: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(expected_uid, "user ID")
    claims = require_email_verified(verify_id_token(id_token))
    if claims.get("uid") != expected_uid:
        raise BootstrapDenied("Bootstrap identity mismatch.")
    expected = os.environ.get("INSIGHTFLOW_BOOTSTRAP_SECRET")
    if not expected or bootstrap_secret != expected:
        raise BootstrapDenied("Bootstrap credential rejected.")
    initialize_firebase()
    ref = db.reference(f"workspaces/{workspace_id}")
    def txn(current):
        now = int(time.time() * 1000)
        roles = {rid: {"name": rid.title(), "permissions": sorted(perms), "system": True}
                 for rid, perms in DEFAULT_ROLES.items()}
        if current is None:
            return {
                "bootstrap": {"initialized": True, "owner_uid": expected_uid, "initialized_at": now, "nonce": uuid.uuid4().hex},
                "organization": {
                    "organization_id": workspace_id,
                    "status": "active",
                    "created_at": now,
                },
                "roles": roles,
                "members": {
                    expected_uid: {
                        "employee_id": f"emp_{uuid.uuid4().hex}",
                        "status": "active",
                        "roles": {"owner": True},
                    }
                },
                "resources": {},
            }
        bootstrap = current.get("bootstrap") or {}
        if bootstrap.get("initialized") is True and bootstrap.get("owner_uid") == expected_uid:
            current.setdefault("organization", {
                "organization_id": workspace_id,
                "status": "active",
            })
            current["organization"].setdefault("organization_id", workspace_id)
            current["organization"].setdefault("status", "active")
            current.setdefault("roles", {}).update({k: v for k, v in roles.items() if k not in current.get("roles", {})})
            member = current.setdefault("members", {}).setdefault(
                expected_uid,
                {"roles": {"owner": True}},
            )
            member.setdefault("status", "active")
            member.setdefault("employee_id", f"emp_{expected_uid}")
            current.setdefault("resources", {})
        return current
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
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "roles.manage")
    can_manage_role(workspace_id, actor, target_uid, role_id, enabled)
    if ROLE_ALIASES.get(role_id, role_id) == "organization_owner" and not enabled:
        last_owner_guard(workspace_id, target_uid)
    db.reference(f"workspaces/{workspace_id}/members/{target_uid}/roles/{role_id}").set(bool(enabled))
    return True


def upsert_role(workspace_id: str, role_id: str, name: str, permissions: list[str], actor_token: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(role_id, "role ID")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 100:
        raise ValueError("Invalid role name.")
    permissions = [validate_action(p) for p in permissions]
    claims = require_email_verified(verify_id_token(actor_token))
    authorization(str(claims["uid"]), workspace_id, "roles.manage")
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/roles/{role_id}").set({
        "name": name.strip(), "permissions": sorted(set(permissions)), "system": role_id in DEFAULT_ROLES
    })
    return True

def set_resource_grant(workspace_id: str, resource_id: str, target_uid: str, permissions: list[str], actor_token: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(resource_id, "resource ID")
    validate_id(target_uid, "user ID")
    permissions = [validate_action(p) for p in permissions]
    claims = require_email_verified(verify_id_token(actor_token))
    authorization(str(claims["uid"]), workspace_id, "users.manage")
    workspace = _workspace(workspace_id)
    if target_uid not in (workspace.get("members") or {}):
        raise PermissionDenied("Grant target is not a workspace member.")
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/resources/{resource_id}/grants/{target_uid}").set({
        "permissions": sorted(set(permissions))
    })
    return True
