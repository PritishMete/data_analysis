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
        options = {"projectId": PROJECT_ID, "databaseURL": DATABASE_URL}
        storage_bucket = os.environ.get("FIREBASE_STORAGE_BUCKET", "").strip()
        if storage_bucket:
            options["storageBucket"] = storage_bucket
        return firebase_admin.initialize_app(cred, options)

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
        # Resolve a recreated Firebase account at the authorization boundary too.
        # This keeps Web/Power BI/future clients independent from an earlier /me call.
        initialize_firebase()
        try:
            firebase_user = auth.get_user(uid)
        except auth.UserNotFoundError:
            firebase_user = None
        if firebase_user is not None:
            provider = "firebase"
            provider_subject = uid
            for provider_data in (firebase_user.provider_data or []):
                if provider_data.provider_id:
                    provider = str(provider_data.provider_id)
                    provider_subject = str(provider_data.uid or uid)
                    break
            resolved = resolve_principal(
                uid,
                str(firebase_user.email or ""),
                provider,
                provider_subject,
                bool(firebase_user.email_verified),
            )
            if resolved.get("state") in {"suspended", "removed"}:
                raise PermissionDenied("This account is suspended.")
            value = _raw_user(uid)
    if not value:
        raise PermissionDenied("No InsightFlow organization access is assigned to this account.")
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

def pending_invitations_for_email(email: str) -> list[dict[str, Any]]:
    email = str(email or "").strip().lower()
    if not email or "@" not in email:
        return []
    workspaces = _get("workspaces") or {}
    matches: list[dict[str, Any]] = []
    now = int(time.time() * 1000)
    for workspace_id, workspace in workspaces.items():
        if not isinstance(workspace, dict):
            continue
        organization = _organization_record(workspace_id, workspace)
        for invitation_id, invitation in (workspace.get("invitations") or {}).items():
            if not isinstance(invitation, dict) or invitation.get("status") != "invited":
                continue
            if str(invitation.get("email") or "").strip().lower() != email:
                continue
            expires_at = invitation.get("expires_at")
            if expires_at is not None and int(expires_at) <= now:
                continue
            matches.append({
                "invitation_id": str(invitation.get("invitation_id") or invitation_id),
                "workspace_id": workspace_id,
                "organization_id": organization.get("organization_id", workspace_id),
                "organization_name": organization.get("name") or organization.get("display_name") or organization.get("organization_id", workspace_id),
                "employee_id": invitation.get("employee_id"),
                "role_id": ROLE_ALIASES.get(str(invitation.get("role_id") or ""), str(invitation.get("role_id") or "")),
                "expires_at": expires_at,
            })
    return matches

def authenticated_identity(claims: dict[str, Any]) -> dict[str, Any]:
    """Normalize the Firebase-authenticated identity without coupling RBAC to a provider."""
    firebase_claims = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(firebase_claims.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase_claims.get("identities") if isinstance(firebase_claims.get("identities"), dict) else {}
    subjects = identities.get(provider) if isinstance(identities, dict) else None
    provider_subject = str(subjects[0]) if isinstance(subjects, list) and subjects else str(claims.get("sub") or claims.get("uid") or "")
    return {
        "provider": provider,
        "provider_subject": provider_subject,
        "verified_email": str(claims.get("email") or "").strip().lower(),
        "firebase_uid": str(claims.get("uid") or ""),
        "display_name": claims.get("name"),
    }

def _identity_candidates(email: str, provider: str, provider_subject: str) -> list[dict[str, Any]]:
    """Find eligible existing members by verified provider subject only.

    Recreated Firebase UIDs are relinked through the stable provider subject
    retained in the member identity binding. Email alone is intentionally not
    sufficient proof of continuity.
    """
    email = str(email or "").strip().lower()
    provider = str(provider or "").strip().lower()
    provider_subject = str(provider_subject or "").strip()
    if not provider or not provider_subject:
        return []
    workspaces = _get("workspaces") or {}
    candidates: list[dict[str, Any]] = []
    for workspace_id, workspace in workspaces.items():
        if not isinstance(workspace, dict):
            continue
        for member_uid, member in (workspace.get("members") or {}).items():
            if not isinstance(member, dict):
                continue
            status = _membership_status(member)
            employee_id = str(member.get("employee_id") or "").strip()
            if not employee_id:
                continue
            linked = member.get("identity_bindings") or {}
            provider_values = linked.get(provider) if isinstance(linked, dict) else None
            if not isinstance(provider_values, list):
                continue
            if provider_subject not in {str(value) for value in provider_values}:
                continue
            candidates.append({
                "workspace_id": workspace_id,
                "member_uid": str(member_uid),
                "employee_id": employee_id,
                "status": status,
                "match": "provider_subject",
            })
    unique = {(item["workspace_id"], item["member_uid"]): item for item in candidates}
    return list(unique.values())

def resolve_principal(
    uid: str,
    email: str | None = None,
    provider: str = "firebase",
    provider_subject: str | None = None,
    email_verified: bool = False,
) -> dict[str, Any]:
    """Resolve the authenticated identity to the stable organization member identity."""
    uid = validate_id(uid, "user ID")
    normalized_email = str(email or "").strip().lower()
    subject = str(provider_subject or uid)
    user = _raw_user(uid)
    if user:
        status = str(user.get("status") or "active").strip().lower()
        if user.get("suspended") is True or status in {"suspended", "disabled"}:
            return {"state": "suspended", "firebase_uid": uid, "principal_id": user.get("principal_id")}
        if status == "removed":
            return {"state": "removed", "firebase_uid": uid, "principal_id": user.get("principal_id")}
        principal_id = str(user.get("principal_id") or user.get("employee_id") or "").strip()
        linked_member_uid = str(user.get("linked_member_uid") or uid).strip()
        linked_workspace_id = str(
            user.get("linked_organization_id")
            or user.get("bootstrap_organization_id")
            or ""
        ).strip()
        if linked_workspace_id:
            workspace = _workspace(linked_workspace_id)
            member = (workspace.get("members") or {}).get(linked_member_uid)
            if isinstance(member, dict):
                member_status = _membership_status(member)
                if member_status in {"suspended", "removed"}:
                    return {
                        "state": "suspended" if member_status == "suspended" else "removed",
                        "firebase_uid": uid,
                        "principal_id": principal_id or member.get("principal_id") or member.get("employee_id"),
                        "member_uid": linked_member_uid,
                        "workspace_id": linked_workspace_id,
                    }
                if member_status in {"invited", "approved"}:
                    return {
                        "state": "pending_employee",
                        "firebase_uid": uid,
                        "principal_id": principal_id or member.get("principal_id") or member.get("employee_id"),
                        "member_uid": linked_member_uid,
                        "workspace_id": linked_workspace_id,
                    }
                if member_status == "active":
                    return {
                        "state": "active_identity",
                        "firebase_uid": uid,
                        "principal_id": principal_id or member.get("principal_id") or member.get("employee_id") or uid,
                        "member_uid": linked_member_uid,
                        "workspace_id": linked_workspace_id,
                        "relinked": False,
                    }
            return {
                "state": "no_organization_access",
                "firebase_uid": uid,
                "principal_id": principal_id or uid,
            }
        return {
            "state": "active_identity",
            "firebase_uid": uid,
            "principal_id": principal_id or uid,
            "member_uid": linked_member_uid,
            "relinked": False,
        }
    if not email_verified or not normalized_email:
        return {"state": "new_company_candidate", "firebase_uid": uid, "principal_id": uid}
    candidates = _identity_candidates(normalized_email, provider, subject)
    if len(candidates) != 1:
        if len(candidates) > 1:
            return {"state": "ambiguous_identity", "firebase_uid": uid, "principal_id": uid}
        return {"state": "new_company_candidate", "firebase_uid": uid, "principal_id": uid}
    candidate = candidates[0]
    if candidate.get("status") in {"suspended", "removed"}:
        return {
            "state": "suspended",
            "firebase_uid": uid,
            "principal_id": candidate.get("employee_id"),
            "member_uid": candidate.get("member_uid"),
        }
    if candidate["match"] != "provider_subject":
        return {"state": "new_company_candidate", "firebase_uid": uid, "principal_id": uid}
    initialize_firebase()
    now = int(time.time() * 1000)
    member_path = f"workspaces/{candidate['workspace_id']}/members/{candidate['member_uid']}"
    member = _get(member_path) or {}
    bindings = dict(member.get("identity_bindings") or {})
    values = list(bindings.get(provider) or [])
    if subject and subject not in values:
        values.append(subject)
    bindings[provider] = sorted(set(str(v) for v in values))
    db.reference(member_path).update({
        "principal_id": candidate["employee_id"],
        "identity_bindings": bindings,
        "identity_relinked_at": now,
        "identity_relinked_from": candidate["member_uid"],
    })
    db.reference(f"users/{uid}").set({
        "status": "active",
        "email": normalized_email,
        "employee_id": candidate["employee_id"],
        "principal_id": candidate["employee_id"],
        "linked_member_uid": candidate["member_uid"],
        "linked_organization_id": candidate["workspace_id"],
        "identity_provider": provider,
        "identity_provider_subject": subject,
        "created_at": now,
    })
    audit_event(
        candidate["workspace_id"], uid, "identity.relink", "succeeded",
        target_uid=candidate["member_uid"],
        metadata={"provider": provider, "match": candidate["match"]},
    )
    return {
        "state": "relinked",
        "firebase_uid": uid,
        "principal_id": candidate["employee_id"],
        "member_uid": candidate["member_uid"],
        "workspace_id": candidate["workspace_id"],
        "relinked": True,
    }

def _member_key_for_workspace(workspace: dict[str, Any], uid: str, user: dict[str, Any] | None = None) -> str | None:
    members = workspace.get("members") or {}
    if isinstance(members.get(uid), dict):
        return uid
    if user is None:
        try:
            user = _raw_user(uid)
        except RuntimeError:
            user = {}
    linked_member_uid = str(user.get("linked_member_uid") or "").strip()
    if linked_member_uid and isinstance(members.get(linked_member_uid), dict):
        return linked_member_uid
    principal_id = str(user.get("principal_id") or user.get("employee_id") or "").strip()
    if principal_id:
        matches = [
            key for key, member in members.items()
            if isinstance(member, dict)
            and str(member.get("principal_id") or member.get("employee_id") or "").strip() == principal_id
            and _membership_status(member) not in {"removed"}
        ]
        if len(matches) == 1:
            return str(matches[0])
    return None

def authentication_context(uid: str, workspace_id: str | None = None, email_verified: bool = False, email: str | None = None, provider: str = "firebase", provider_subject: str | None = None) -> dict[str, Any]:
    validate_id(uid, "user ID")
    if workspace_id:
        validate_id(workspace_id, "workspace ID")
    principal = resolve_principal(uid, email, provider, provider_subject, email_verified)
    if principal["state"] == "suspended":
        return {
            "email_verified": bool(email_verified),
            "account_status": "suspended",
            "membership_status": "suspended",
            "workspace_authorized": False,
            "authorization_state": "suspended",
            "has_authorization_record": True,
            "principal_id": principal.get("principal_id"),
            "workspaces": [],
            "pending_invitations": [],
        }
    if principal["state"] == "removed":
        return {
            "email_verified": bool(email_verified),
            "account_status": "removed",
            "membership_status": "removed",
            "workspace_authorized": False,
            "authorization_state": "removed",
            "has_authorization_record": True,
            "principal_id": principal.get("principal_id"),
            "workspaces": [],
            "pending_invitations": [],
        }
    if principal["state"] == "ambiguous_identity":
        return {
            "email_verified": bool(email_verified),
            "account_status": "pending",
            "membership_status": "none",
            "workspace_authorized": False,
            "authorization_state": "ambiguous_identity",
            "has_authorization_record": False,
            "principal_id": uid,
            "pending_invitations": [],
            "workspaces": [],
        }
    invitations = pending_invitations_for_email(str(email or ""))
    memberships = workspace_memberships(uid, include_user=False)
    selected = next((item for item in memberships if workspace_id and item["workspace_id"] == workspace_id), None)
    if selected is None and not workspace_id:
        active_memberships = [item for item in memberships if item["membership_status"] == "active"]
        if len(active_memberships) == 1:
            selected = active_memberships[0]
    membership_status = selected["membership_status"] if selected else "none"
    account_status = "active" if principal["state"] in {"active_identity", "relinked"} else "pending"
    workspace_authorized = bool(email_verified and account_status == "active" and membership_status == "active")
    if membership_status == "active" and workspace_authorized:
        authorization_state = "active_member"
    elif membership_status in {"invited", "approved"}:
        authorization_state = "approved_employee_pending_link"
    elif invitations:
        authorization_state = "pending_invitation"
    elif principal["state"] in {"relinked"}:
        authorization_state = "active_member" if workspace_authorized else "no_organization_access"
    elif principal["state"] in {"no_organization_access", "active_identity", "pending_employee"}:
        authorization_state = (
            "approved_employee_pending_link"
            if principal["state"] == "pending_employee"
            else "no_organization_access"
        )
    else:
        authorization_state = "new_company_candidate"
    return {
        "email_verified": bool(email_verified),
        "account_status": account_status,
        "membership_status": membership_status,
        "workspace_authorized": workspace_authorized,
        "authorization_state": authorization_state,
        "has_authorization_record": principal["state"] in {"active_identity", "relinked"},
        "principal_id": principal.get("principal_id"),
        "workspace_id": selected.get("workspace_id") if selected else workspace_id,
        "organization_id": selected.get("organization_id") if selected else None,
        "employee_id": selected.get("employee_id") if selected else principal.get("principal_id"),
        "pending_invitations": invitations,
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
        member_key = _member_key_for_workspace(workspace, uid)
        member = (workspace.get("members") or {}).get(member_key) if member_key else None
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
                "employee_id": str(member.get("employee_id") or f"emp_{member_key or uid}"),
                "principal_id": str(member.get("principal_id") or member.get("employee_id") or member_key or uid),
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
    permissions = {p for p in permissions if p in ACTIONS}
    level = _effective_role_level(member)
    if level >= ROLE_LEVELS["manager"]:
        permissions.add("dataset.upload")
    if level >= ROLE_LEVELS["manager"] and "worksheet.modify" in permissions:
        permissions.add("excel.mutate.original")
    if level >= ROLE_LEVELS["employee"] and level < ROLE_LEVELS["manager"] and "worksheet.modify" in permissions:
        permissions.add("excel.mutate.working_copy")
    return permissions

def _stable_identity_keys(uid: str, user: dict[str, Any] | None = None) -> list[str]:
    keys = [uid]
    if user is None:
        try:
            user = _raw_user(uid)
        except RuntimeError:
            user = {}
    for value in (user.get("linked_member_uid"), user.get("principal_id"), user.get("employee_id")):
        value = str(value or "").strip()
        if value and value not in keys:
            keys.append(value)
    return keys

def _resource_grant(workspace: dict[str, Any], uid: str, resource_id: str, user: dict[str, Any] | None = None) -> dict[str, Any]:
    resource_id = validate_id(resource_id, "resource ID")
    resource = (workspace.get("resources") or {}).get(resource_id)
    if not isinstance(resource, dict):
        raise PermissionDenied("Resource is not accessible.")
    grants = resource.get("grants") or {}
    if not grants:
        return {}
    direct = grants.get(uid)
    if isinstance(direct, dict):
        return direct
    for key in _stable_identity_keys(uid, user):
        grant = grants.get(key)
        if isinstance(grant, dict):
            return grant
    return {}


def authorization(uid: str, workspace_id: str, action: str, resource_id: str | None = None) -> dict[str, Any]:
    validate_id(uid, "user ID")
    validate_id(workspace_id, "workspace ID")
    validate_action(action)
    if resource_id is not None:
        validate_id(resource_id, "resource ID")
    requires_resource = action in {"data.view", "analysis.run", "worksheet.create", "pivot.create", "worksheet.modify", "worksheet.delete", "operation.undo.own", "operation.undo.other",
        "excel.mutate.original", "excel.mutate.working_copy"}
    if requires_resource and not resource_id:
        raise PermissionDenied("A resource ID is required for this action.")
    user = _user(uid)
    workspace = _workspace(workspace_id)
    members = workspace.get("members") or {}
    member_key = _member_key_for_workspace(workspace, uid, user)
    member = members.get(member_key) if member_key else None
    if not isinstance(member, dict):
        raise PermissionDenied("User is not a member of this workspace.")
    if _membership_status(member) != "active":
        raise PermissionDenied("User membership is not active.")

    permissions = _role_permissions(workspace, member)

    if resource_id:
        grant = _resource_grant(workspace, uid, resource_id, user)
        grant_permissions = {p for p in (grant.get("permissions") or []) if p in ACTIONS}
        level = _effective_role_level(member)
        if action == "excel.mutate.original" and level >= ROLE_LEVELS["manager"] and "worksheet.modify" in grant_permissions:
            grant_permissions.add("excel.mutate.original")
        if action == "excel.mutate.working_copy" and level < ROLE_LEVELS["manager"] and "worksheet.modify" in grant_permissions:
            grant_permissions.add("excel.mutate.working_copy")
        permissions &= grant_permissions
        if action not in permissions:
            raise PermissionDenied("Permission denied for this resource.")

    if action not in permissions:
        raise PermissionDenied("Permission denied.")
    return {
        "allowed": True, "uid": uid, "principal_id": str(member.get("principal_id") or member.get("employee_id") or member_key or uid),
        "workspace_id": workspace_id, "action": action, "resource_id": resource_id,
        "role_ids": _effective_role_ids(member),
    }

def _dataset(workspace: dict[str, Any], dataset_id: str) -> dict[str, Any]:
    dataset_id = validate_id(dataset_id, "dataset ID")
    datasets = workspace.get("datasets") or {}
    value = datasets.get(dataset_id)
    if not isinstance(value, dict):
        raise PermissionDenied("Dataset is not accessible.")
    return value

def _dataset_grant(dataset: dict[str, Any], uid: str) -> dict[str, Any]:
    grants = dataset.get("grants") or {}
    if not grants:
        return {}
    direct = grants.get(uid)
    if isinstance(direct, dict):
        return direct
    for key in _stable_identity_keys(uid):
        grant = grants.get(key)
        if isinstance(grant, dict):
            return grant
    return {}

DELEGATED_DATASET_PERMISSIONS = {
    "dataset.view_original",
    "dataset.create_working_copy",
    "dataset.share",
}

def _approved_employee(workspace: dict[str, Any], uid: str) -> bool:
    records = workspace.get("approved_employees") or {}
    direct = records.get(uid)
    if isinstance(direct, dict):
        return str(direct.get("status") or "active") == "active"
    for key in _stable_identity_keys(uid):
        record = records.get(key)
        if isinstance(record, dict):
            return str(record.get("status") or "active") == "active"
    return False

def set_approved_employee(workspace_id: str, target_uid: str, employee_id: str, actor_token: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(target_uid, "user ID")
    validate_id(employee_id, "employee ID")
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "membership.manage")
    workspace = _workspace(workspace_id)
    member = (workspace.get("members") or {}).get(target_uid)
    if not isinstance(member, dict) or _membership_status(member) != "active":
        raise PermissionDenied("Approved employee must be an active organization member.")
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/approved_employees/{target_uid}").set({
        "employee_id": employee_id,
        "status": "active",
        "approved_at": int(time.time() * 1000),        "approved_by": actor,
    })
    return True

def set_delegation(
    workspace_id: str,
    team_lead_uid: str,
    member_ids: list[str],
    dataset_ids: list[str],
    permissions: list[str],
    expires_at: int | None,
    actor_token: str,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(team_lead_uid, "user ID")
    member_ids = [validate_id(uid, "member ID") for uid in member_ids]
    dataset_ids = [validate_id(dataset_id, "dataset ID") for dataset_id in dataset_ids]
    if any(permission not in DELEGATED_DATASET_PERMISSIONS for permission in permissions):
        raise ValueError("Delegation contains an unsupported capability.")
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "delegation.manage")
    workspace = _workspace(workspace_id)
    team_lead = (workspace.get("members") or {}).get(team_lead_uid)
    if not isinstance(team_lead, dict):
        raise PermissionDenied("Delegated administrator must be an organization member.")
    if "team_lead" not in _effective_role_ids(team_lead):
        raise PermissionDenied("Delegation target must have the Team Lead role.")
    for uid in member_ids:
        member = (workspace.get("members") or {}).get(uid)
        if not isinstance(member, dict) or _membership_status(member) != "active":
            raise PermissionDenied("Delegation scope contains an inactive member.")
        if not _approved_employee(workspace, uid):
            raise PermissionDenied("Delegation scope can contain only approved employees.")
    for dataset_id in dataset_ids:
        _dataset(workspace, dataset_id)
    if expires_at is not None and expires_at <= int(time.time() * 1000):
        raise ValueError("Delegation expiry must be in the future.")
    initialize_firebase()
    delegation_id = uuid.uuid4().hex
    db.reference(f"workspaces/{workspace_id}/delegations/{delegation_id}").set({
        "delegation_id": delegation_id,
        "delegated_by": actor,
        "team_lead_uid": team_lead_uid,
        "member_ids": sorted(set(member_ids)),
        "dataset_ids": sorted(set(dataset_ids)),
        "permissions": sorted(set(permissions)),
        "expires_at": expires_at,
        "status": "active",
        "created_at": int(time.time() * 1000),
    })
    return {"delegation_id": delegation_id}

def _delegated_permission(
    workspace: dict[str, Any],
    actor_uid: str,
    target_uid: str,
    dataset_id: str,
    action: str,
) -> bool:
    now = int(time.time() * 1000)
    delegations = workspace.get("delegations") or {}
    for delegation in delegations.values():
        if not isinstance(delegation, dict):
            continue
        if delegation.get("status") != "active":
            continue
        if delegation.get("team_lead_uid") != actor_uid:
            continue
        expiry = delegation.get("expires_at")
        if expiry is not None and int(expiry) <= now:
            continue
        if target_uid not in (delegation.get("member_ids") or []):
            continue
        if dataset_id not in (delegation.get("dataset_ids") or []):
            continue
        if action in set(delegation.get("permissions") or []):
            return True
    return False

def create_working_copy(
    workspace_id: str,
    dataset_id: str,
    actor_token: str,
    working_copy_id: str | None = None,
    source_version: str | None = None,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(dataset_id, "dataset ID")
    if working_copy_id is not None:
        validate_id(working_copy_id, "working copy ID")
    if source_version is not None:
        validate_id(source_version, "source version")
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    authorize_dataset(actor, workspace_id, dataset_id, "dataset.create_working_copy")
    workspace = _workspace(workspace_id)
    dataset = _dataset(workspace, dataset_id)
    copy_id = working_copy_id or f"wc_{uuid.uuid4().hex}"
    now = int(time.time() * 1000)
    metadata = {
        "working_copy_id": copy_id,
        "organization_id": workspace_id,
        "source_dataset_id": dataset_id,
        "source_owner_uid": dataset.get("owner_uid"),
        "created_by_uid": actor,
        "status": "active",
        "source_version": source_version or "1",
        "version": 1,
        "created_at": now,
        "provenance": {
            "source_dataset_id": dataset_id,
            "source_version": source_version or "1",
            "created_by_uid": actor,
            "created_at": now,
        },
        "grants": {
            actor: {
                "permissions": [
                    "working_copy.view",
                    "working_copy.modify",
                    "working_copy.delete",
                ]
            }
        },
    }
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/working_copies/{copy_id}").set(metadata)
    return {
        "working_copy_id": copy_id,
        "organization_id": workspace_id,
        "source_dataset_id": dataset_id,
        "source_version": source_version or "1",
    }

def authorize_working_copy(
    uid: str,
    workspace_id: str,
    working_copy_id: str,
    action: str,
):
    validate_id(working_copy_id, "working copy ID")
    if action not in {
        "working_copy.view",
        "working_copy.modify",
        "working_copy.delete",
    }:
        raise ValueError("Invalid working copy action.")
    decision = authorization(uid, workspace_id, action, None)
    workspace = _workspace(workspace_id)
    copies = workspace.get("working_copies") or {}
    working_copy = copies.get(working_copy_id)
    if not isinstance(working_copy, dict):
        raise PermissionDenied("Working copy is not accessible.")
    if working_copy.get("status") != "active":
        raise PermissionDenied("Working copy is not active.")
    grant = {}
    for key in _stable_identity_keys(uid):
        candidate = (working_copy.get("grants") or {}).get(key)
        if isinstance(candidate, dict):
            grant = candidate
            break
    if action not in set(grant.get("permissions") or []):
        if working_copy.get("created_by_uid") not in _stable_identity_keys(uid):
            raise PermissionDenied("Permission denied for this working copy.")
    return {
        **decision,
        "working_copy_id": working_copy_id,
        "source_dataset_id": working_copy.get("source_dataset_id"),
        "source_version": working_copy.get("source_version"),
        "version": working_copy.get("version"),
        "provenance": working_copy.get("provenance"),
    }

def register_dataset(workspace_id: str, dataset_id: str, owner_uid: str, actor_token: str, protected: bool = True):
    validate_id(workspace_id, "workspace ID")
    validate_id(dataset_id, "dataset ID")
    validate_id(owner_uid, "user ID")
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    workspace = _workspace(workspace_id)
    try:
        authorization(actor, workspace_id, "dataset.manage_acl")
    except PermissionDenied:
        if not _delegated_permission(
            workspace, actor, owner_uid, dataset_id, "dataset.create_working_copy"
        ):
            raise
    owner_member_uid = _member_key_for_workspace(workspace, owner_uid)
    members = workspace.get("members") or {}
    owner_member = members.get(owner_member_uid) if owner_member_uid else None
    if not isinstance(owner_member, dict) or _membership_status(owner_member) != "active":
        raise PermissionDenied("Dataset owner must be an active organization member.")
    principal_id = str(
        owner_member.get("principal_id")
        or owner_member.get("employee_id")
        or owner_member_uid
    )
    initialize_firebase()
    now = int(time.time() * 1000)
    db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}").set({
        "dataset_id": dataset_id,
        "organization_id": workspace_id,
        "owner_uid": owner_member_uid,
        "owner_principal_id": principal_id,
        "protected_original": bool(protected),
        "created_at": now,
        "grants": {
            owner_member_uid: {
                "permissions": [
                    "dataset.view_original",
                    "dataset.create_working_copy",
                    "dataset.manage_acl",
                ]
            }
        },
    })
    return {"dataset_id": dataset_id, "organization_id": workspace_id}

def authorize_excel_mutation(
    uid: str,
    workspace_id: str,
    action: str,
    dataset_id: str,
):
    validate_id(dataset_id, "dataset ID")
    if action == "excel.mutate.original":
        # Original-workbook mutation requires the role capability plus an
        # explicit dataset grant. The dataset grant is the resource boundary;
        # do not route this through legacy workspace.resources ACLs.
        decision = authorization(uid, workspace_id, "worksheet.modify", None)
        authorize_dataset(uid, workspace_id, dataset_id, "dataset.view_original")
        return {
            **decision,
            "action": action,
            "resource_id": dataset_id,
            "protected_original": True,
        }
    if action == "excel.mutate.working_copy":
        return authorize_working_copy(uid, workspace_id, dataset_id, "working_copy.modify")
    raise ValueError("Unsupported Excel mutation capability.")

def set_dataset_grant(
    workspace_id: str,
    dataset_id: str,
    target_uid: str,
    permissions: list[str],
    actor_token: str,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(dataset_id, "dataset ID")
    validate_id(target_uid, "user ID")
    allowed = {
        "dataset.view_original",
        "dataset.create_working_copy",
        "dataset.edit_working_copy",
        "dataset.share",
    }
    if any(permission not in allowed for permission in permissions):
        raise ValueError("Invalid dataset permission.")
    claims = require_recent_auth(require_email_verified(verify_id_token(actor_token)))
    actor = str(claims["uid"])
    workspace = _workspace(workspace_id)
    target_member_uid = _member_key_for_workspace(workspace, target_uid)
    if not target_member_uid:
        raise PermissionDenied("Grant target is not an organization member.")
    try:
        authorization(actor, workspace_id, "dataset.manage_acl")
    except PermissionDenied:
        if not _delegated_permission(
            workspace, actor, target_member_uid, dataset_id, "dataset.share"
        ):
            raise
    actor_member_uid = _member_key_for_workspace(workspace, actor)
    actor_member = (workspace.get("members") or {}).get(actor_member_uid) if actor_member_uid else None
    if not isinstance(actor_member, dict):
        raise PermissionDenied("Grant actor is not an organization member.")
    if _effective_role_level(actor_member) <= ROLE_LEVELS["team_lead"]:
        if not _approved_employee(workspace, target_member_uid):
            raise PermissionDenied("Team Leads may grant dataset access only to approved employees.")
    dataset = _dataset(workspace, dataset_id)
    actor_grant = _dataset_grant(dataset, actor)
    actor_can_manage = "dataset.manage_acl" in set(actor_grant.get("permissions") or [])
    delegated_share = _delegated_permission(
        workspace, actor_member_uid, target_member_uid, dataset_id, "dataset.share"
    )
    if (
        actor_can_manage is False
        and actor_member_uid != dataset.get("owner_uid")
        and not delegated_share
    ):
        raise PermissionDenied("Dataset ACL management is not delegated to this user.")
    initialize_firebase()
    db.reference(
        f"workspaces/{workspace_id}/datasets/{dataset_id}/grants/{target_member_uid}"
    ).set({"permissions": sorted(set(permissions))})
    return True

def authorize_dataset(uid: str, workspace_id: str, dataset_id: str, action: str):
    if not action.startswith("dataset."):
        raise ValueError("Dataset authorization requires a dataset capability.")
    decision = authorization(uid, workspace_id, action, None)
    workspace = _workspace(workspace_id)
    dataset = _dataset(workspace, dataset_id)
    grants = _dataset_grant(dataset, uid)
    grant_permissions = set(grants.get("permissions") or [])
    if action not in grant_permissions:
        raise PermissionDenied("Permission denied for this dataset.")
    return {
        **decision,
        "dataset_id": dataset_id,
        "protected_original": dataset.get("protected_original") is True,
    }

def can_manage_role(workspace_id: str, actor_uid: str, target_uid: str, role_id: str, enabled: bool) -> bool:
    validate_id(role_id, "role ID")
    workspace = _workspace(workspace_id)
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
    target_status = _membership_status(target)
    if enabled and target_status != "active":
        raise PermissionDenied("Only active members can receive a role.")
    if enabled and normalized_role == "team_lead" and not _approved_employee(workspace, target_uid):
        raise PermissionDenied("Only approved employees can be promoted to Team Lead.")
    return True

def require_recent_auth(claims: dict[str, Any], max_age_seconds: int = 300) -> dict[str, Any]:
    auth_time = claims.get("auth_time")
    if auth_time is None:
        raise PermissionDenied("Recent authentication is required.")
    try:
        age = time.time() - float(auth_time)
    except (TypeError, ValueError):
        raise PermissionDenied("Recent authentication is required.")
    if age < 0 or age > max_age_seconds:
        raise PermissionDenied("Recent authentication is required.")
    return claims

def audit_event(
    workspace_id: str,
    actor_uid: str,
    action: str,
    outcome: str,
    target_uid: str | None = None,
    resource_id: str | None = None,
    metadata: dict[str, Any] | None = None,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(actor_uid, "user ID")
    if target_uid:
        validate_id(target_uid, "target user ID")
    if resource_id:
        validate_id(resource_id, "resource ID")
    safe_metadata = {}
    for key, value in (metadata or {}).items():
        key = str(key)
        if any(token in key.lower() for token in ("row", "value", "cell", "workbook", "sheet", "prompt", "result", "schema")):
            continue
        if isinstance(value, (str, int, float, bool)) or value is None:
            safe_metadata[key] = value
    initialize_firebase()
    event_id = uuid.uuid4().hex
    db.reference(f"audit/{workspace_id}/{event_id}").set({
        "event_id": event_id,
        "organization_id": workspace_id,
        "actor_uid": actor_uid,
        "action": action,
        "outcome": outcome,
        "target_uid": target_uid,
        "resource_id": resource_id,
        "metadata": safe_metadata,
        "created_at": int(time.time() * 1000),
    })
    return event_id

def _invitation_by_id(workspace: dict[str, Any], invitation_id: str):
    invitations = workspace.get("invitations") or {}
    invitation = invitations.get(invitation_id)
    if not isinstance(invitation, dict):
        raise PermissionDenied("Invitation is not accessible.")
    return invitation

def create_invitation(
    workspace_id: str,
    email: str,
    employee_id: str,
    role_id: str,
    actor_token: str,
    expires_at: int | None = None,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(employee_id, "employee ID")
    validate_id(role_id, "role ID")
    email = email.strip().lower()
    if "@" not in email or len(email) > 320:
        raise ValueError("Invalid invitation email.")
    normalized_role = ROLE_ALIASES.get(role_id, role_id)
    if normalized_role not in {"team_lead", "employee", "external_viewer"}:
        raise PermissionDenied("Invitations cannot directly assign Owner or Manager access.")
    claims = require_recent_auth(require_email_verified(verify_id_token(actor_token)))
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "invitation.manage")
    workspace = _workspace(workspace_id)
    if expires_at is not None and expires_at <= int(time.time() * 1000):
        raise ValueError("Invitation expiry must be in the future.")
    invitation_id = uuid.uuid4().hex
    now = int(time.time() * 1000)
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/invitations/{invitation_id}").set({
        "invitation_id": invitation_id,
        "organization_id": workspace_id,
        "email": email,
        "employee_id": employee_id,
        "role_id": normalized_role,
        "status": "invited",
        "created_by": actor,
        "created_at": now,
        "expires_at": expires_at,
    })
    audit_event(
        workspace_id, actor, "invitation.create", "succeeded",
        metadata={"role_id": normalized_role},
    )
    return {"invitation_id": invitation_id, "status": "invited"}

def accept_invitation(workspace_id: str, invitation_id: str, actor_token: str):
    validate_id(workspace_id, "workspace ID")
    validate_id(invitation_id, "invitation ID")
    claims = require_email_verified(verify_id_token(actor_token))
    actor = str(claims["uid"])
    email = str(claims.get("email") or "").strip().lower()
    provider, provider_subject = _claims_identity_binding(claims)
    try:
        existing_user = _raw_user(actor)
    except RuntimeError:
        existing_user = {}
    if existing_user:
        status = str(existing_user.get("status") or "active").strip().lower()
        if existing_user.get("suspended") is True or status in {"suspended", "disabled", "removed"}:
            raise PermissionDenied("This account is suspended.")
    workspace = _workspace(workspace_id)
    invitation = _invitation_by_id(workspace, invitation_id)
    if invitation.get("status") != "invited":
        raise PermissionDenied("Invitation is no longer active.")
    if invitation.get("expires_at") is not None and int(invitation["expires_at"]) <= int(time.time() * 1000):
        raise PermissionDenied("Invitation has expired.")
    if invitation.get("email") != email:
        raise PermissionDenied("Invitation identity does not match the authenticated email.")
    member_ref = db.reference(f"workspaces/{workspace_id}/members/{actor}")
    employee_id = invitation.get("employee_id") or f"emp_{actor}"
    member_ref.set({
        "employee_id": employee_id,
        "principal_id": employee_id,
        "status": "active",
        "roles": {str(invitation["role_id"]): True},
        "identity_bindings": {provider: [provider_subject]},
    })
    db.reference(f"workspaces/{workspace_id}/invitations/{invitation_id}").update({
        "status": "accepted",
        "accepted_by": actor,
        "accepted_at": int(time.time() * 1000),
    })
    db.reference(f"users/{actor}").set({
        "status": "active",
        "email": email,
        "employee_id": employee_id,
        "principal_id": employee_id,
        "linked_member_uid": actor,
        "linked_organization_id": workspace_id,
        "identity_provider": provider,
        "identity_provider_subject": provider_subject,
    })
    audit_event(
        workspace_id, actor, "invitation.accept", "succeeded",
        target_uid=actor,
        metadata={"role_id": invitation.get("role_id")},
    )
    return {"accepted": True, "organization_id": workspace_id}

def management_snapshot(uid: str, workspace_id: str, claims: dict[str, Any]) -> dict[str, Any]:
    require_email_verified(claims)
    validate_id(uid, "user ID")
    validate_id(workspace_id, "workspace ID")
    authorization(uid, workspace_id, "organization.view")
    workspace = _workspace(workspace_id)
    member_key = _member_key_for_workspace(workspace, uid)
    member = (workspace.get("members") or {}).get(member_key) or {}
    capabilities = _role_permissions(workspace, member)
    result: dict[str, Any] = {
        "organization_id": workspace_id,
        "workspace_id": workspace_id,
        "role_ids": _effective_role_ids(member),
        "members": [],
        "datasets": [],
        "working_copies": [],
        "invitations": [],
        "approved_employees": [],
        "delegations": [],
        "audit": [],
    }
    is_manager = "membership.manage" in capabilities
    if "membership.view" in capabilities:
        for member_uid, item in (workspace.get("members") or {}).items():
            if isinstance(item, dict):
                result["members"].append({
                    "uid": member_uid,
                    "employee_id": item.get("employee_id") or f"emp_{member_uid}",
                    "membership_status": _membership_status(item),
                    "role_ids": _effective_role_ids(item),
                })
    delegated_dataset_ids = {
        dataset_id
        for delegation in (workspace.get("delegations") or {}).values()
        if isinstance(delegation, dict)
        and delegation.get("team_lead_uid") == uid
        and delegation.get("status") == "active"
        and (
            delegation.get("expires_at") is None
            or int(delegation.get("expires_at")) > int(time.time() * 1000)
        )
        for dataset_id in (delegation.get("dataset_ids") or [])
    }
    for dataset_id, dataset in (workspace.get("datasets") or {}).items():
        if not isinstance(dataset, dict):
            continue
        grant = _dataset_grant(dataset, uid)
        identity_keys = _stable_identity_keys(uid)
        if (
            is_manager
            or dataset.get("owner_uid") in identity_keys
            or dataset.get("owner_principal_id") in identity_keys
            or dataset_id in delegated_dataset_ids
            or "dataset.view_original" in set(grant.get("permissions") or [])
        ):
            result["datasets"].append({
                "dataset_id": dataset_id,
                "display_name": dataset.get("display_name") or dataset.get("original_filename") or dataset_id,
                "original_filename": dataset.get("original_filename"),
                "content_type": dataset.get("content_type"),
                "file_size": dataset.get("file_size"),
                "current_version": dataset.get("current_version"),
                "version": dataset.get("version", 1),
                "status": dataset.get("status", "active"),
                "created_at": dataset.get("created_at"),
                "updated_at": dataset.get("updated_at"),
                "storage_provider": dataset.get("storage_provider"),
                "protected_original": dataset.get("protected_original") is True,
                "owner_uid": dataset.get("owner_uid"),
                "grants": [
                    {
                        "uid": grant_uid,
                        "permissions": list((grant or {}).get("permissions") or []),
                    }
                    for grant_uid, grant in (dataset.get("grants") or {}).items()
                    if isinstance(grant, dict)
                ],
            })
    for copy_id, item in (workspace.get("working_copies") or {}).items():
        if isinstance(item, dict) and (
            item.get("created_by_uid") in _stable_identity_keys(uid) or any(key in (item.get("grants") or {}) for key in _stable_identity_keys(uid))
        ):
            result["working_copies"].append({
                "working_copy_id": copy_id,
                "source_dataset_id": item.get("source_dataset_id"),
                "source_version": item.get("source_version"),
                "status": item.get("status"),
                "created_by_uid": item.get("created_by_uid"),
            })
    if "invitation.manage" in capabilities:
        for invitation_id, invitation in (workspace.get("invitations") or {}).items():
            if isinstance(invitation, dict):
                result["invitations"].append({
                    "invitation_id": invitation_id,
                    "email": invitation.get("email"),
                    "employee_id": invitation.get("employee_id"),
                    "role_id": invitation.get("role_id"),
                    "status": invitation.get("status"),
                    "expires_at": invitation.get("expires_at"),
                })
    if "membership.manage" in capabilities or "delegation.manage" in capabilities:
        allowed_employee_ids = None
        if "delegation.manage" in capabilities and "membership.manage" not in capabilities:
            allowed_employee_ids = {
                member_uid
                for delegation in (workspace.get("delegations") or {}).values()
                if isinstance(delegation, dict)
                and delegation.get("team_lead_uid") == uid
                for member_uid in (delegation.get("member_ids") or [])
            }
        for member_uid, item in (workspace.get("approved_employees") or {}).items():
            if isinstance(item, dict) and (
                allowed_employee_ids is None or member_uid in allowed_employee_ids
            ):                result["approved_employees"].append({
                    "uid": member_uid,
                    "employee_id": item.get("employee_id"),
                    "status": item.get("status"),
                })
    for delegation_id, delegation in (workspace.get("delegations") or {}).items():
        if not isinstance(delegation, dict):
            continue
        if delegation.get("team_lead_uid") == uid or "delegation.manage" in capabilities:
            result["delegations"].append({
                "delegation_id": delegation_id,
                "team_lead_uid": delegation.get("team_lead_uid"),
                "member_ids": delegation.get("member_ids") or [],
                "dataset_ids": delegation.get("dataset_ids") or [],
                "permissions": delegation.get("permissions") or [],
                "expires_at": delegation.get("expires_at"),
                "status": delegation.get("status"),
            })

    if "delegation.manage" in capabilities:
        for delegation_id, delegation in (workspace.get("delegations") or {}).items():
            if isinstance(delegation, dict):
                result.setdefault("delegations", []).append({
                    "delegation_id": delegation_id,
                    "team_lead_uid": delegation.get("team_lead_uid"),
                    "member_ids": delegation.get("member_ids") or [],
                    "dataset_ids": delegation.get("dataset_ids") or [],
                    "permissions": delegation.get("permissions") or [],
                    "expires_at": delegation.get("expires_at"),
                    "status": delegation.get("status"),
                })
    if "audit.view" in capabilities:
        audit = _get(f"audit/{workspace_id}") or {}
        if isinstance(audit, dict):
            for event_id, event in list(audit.items())[-100:]:
                if isinstance(event, dict):
                    result["audit"].append({
                        "event_id": event_id,
                        "actor_uid": event.get("actor_uid"),
                        "action": event.get("action"),                        "outcome": event.get("outcome"),
                        "target_uid": event.get("target_uid"),
                        "resource_id": event.get("resource_id"),
                        "metadata": event.get("metadata") or {},
                        "created_at": event.get("created_at"),
                    })
    return result

def set_membership_status(
    workspace_id: str,
    target_uid: str,
    status: str,
    actor_token: str,
):
    validate_id(workspace_id, "workspace ID")
    validate_id(target_uid, "user ID")
    if status not in {"approved", "active", "suspended", "removed"}:
        raise ValueError("Invalid membership status.")
    claims = require_recent_auth(require_email_verified(verify_id_token(actor_token)))
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "membership.manage")
    if status in {"suspended", "removed"}:
        last_owner_guard(workspace_id, target_uid)
    workspace = _workspace(workspace_id)
    member = (workspace.get("members") or {}).get(target_uid)
    if not isinstance(member, dict):
        raise PermissionDenied("User is not an organization member.")
    initialize_firebase()
    db.reference(f"workspaces/{workspace_id}/members/{target_uid}/status").set(status)
    if status in {"suspended", "removed"} and auth is not None:
        try:
            auth.revoke_refresh_tokens(target_uid)
        except Exception:
            pass
    audit_event(
        workspace_id, actor, "membership.status", "succeeded",
        target_uid=target_uid, metadata={"status": status},
    )
    return True

def require_email_verified(claims: dict[str, Any]) -> dict[str, Any]:
    if claims.get("email_verified") is not True:
        raise EmailVerificationRequired("Email verification required.")
    return claims

def cleanup_account(uid: str, actor_token: str):
    validate_id(uid, "user ID")
    claims = require_recent_auth(require_email_verified(verify_id_token(actor_token)))
    actor = str(claims["uid"])
    if actor != uid:
        raise PermissionDenied("Account cleanup identity mismatch.")
    initialize_firebase()
    workspaces = _get("workspaces") or {}
    affected = []
    for workspace_id, workspace in workspaces.items():
        if not isinstance(workspace, dict):
            continue
        members = workspace.get("members") or {}
        if uid not in members:
            continue
        last_owner_guard(workspace_id, uid)
        affected.append(workspace_id)
        updates = {}
        updates[f"workspaces/{workspace_id}/members/{uid}/status"] = "removed"
        updates[f"workspaces/{workspace_id}/approved_employees/{uid}"] = None
        for dataset_id, dataset in (workspace.get("datasets") or {}).items():
            if isinstance(dataset, dict):
                updates[f"workspaces/{workspace_id}/datasets/{dataset_id}/grants/{uid}"] = None
        for delegation_id, delegation in (workspace.get("delegations") or {}).items():
            if not isinstance(delegation, dict):
                continue
            if delegation.get("team_lead_uid") == uid or uid in (delegation.get("member_ids") or []):
                updates[f"workspaces/{workspace_id}/delegations/{delegation_id}/status"] = "revoked"
        account_email = str(claims.get("email") or "").strip().lower()
        for invitation_id, invitation in (workspace.get("invitations") or {}).items():
            if isinstance(invitation, dict) and (
                str(invitation.get("target_uid") or "") == uid
                or str(invitation.get("created_for_uid") or "") == uid
                or (
                    account_email
                    and str(invitation.get("email") or "").strip().lower() == account_email
                    and str(invitation.get("status") or "") == "invited"
                )
            ):
                updates[f"workspaces/{workspace_id}/invitations/{invitation_id}/status"] = "revoked"
        audit_event(
            workspace_id, actor, "account.cleanup", "succeeded",
            target_uid=uid,
            metadata={"membership_revoked": True, "authorization_state_revoked": True},
        )
        db.reference("/").update(updates)
    if auth is not None:
        try:
            auth.revoke_refresh_tokens(uid)
        except Exception:
            pass
    db.reference(f"users/{uid}/status").set("removed")
    return {"revoked_workspaces": affected}

def protected_context(id_token: str, workspace_id: str, action: str, resource_id: str | None = None):
    claims = require_email_verified(verify_id_token(id_token))
    return claims, authorization(str(claims["uid"]), workspace_id, action, resource_id)

def _claims_identity_binding(claims: dict[str, Any]) -> tuple[str, str]:
    firebase_claims = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(firebase_claims.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase_claims.get("identities") if isinstance(firebase_claims.get("identities"), dict) else {}
    values = identities.get(provider) if isinstance(identities, dict) else None
    subject = str(values[0]) if isinstance(values, list) and values else str(claims.get("sub") or claims.get("uid") or "")
    return provider, subject

def bootstrap_owner(id_token: str, organization_name: str, allow_any_authenticated: bool = False):
    """Create an authenticated user's organization and Owner membership.

    Registration is intentionally based only on a valid Firebase bearer token
    and a safe organization name. The caller cannot choose organization IDs,
    principal IDs, roles, or permissions.
    """
    organization_name = str(organization_name or "").strip()
    if not 1 <= len(organization_name) <= 120:
        raise ValueError("Organization name must be between 1 and 120 characters.")
    if any(ord(char) < 32 or ord(char) == 127 for char in organization_name):
        raise ValueError("Organization name contains invalid control characters.")

    claims = verify_id_token(id_token)
    if not allow_any_authenticated:
        claims = require_email_verified(claims)
    owner_uid = validate_id(str(claims["uid"]), "user ID")
    owner_email = str(claims.get("email") or "").strip().lower()
    provider, provider_subject = _claims_identity_binding(claims)
    if not allow_any_authenticated and not owner_email:
        raise BootstrapDenied("A verified email is required to create an organization.")

    initialize_firebase()
    root_ref = db.reference("/")
    workspace_id = f"org_{uuid.uuid4().hex}"

    def txn(current):
        root = dict(current or {})
        workspaces = dict(root.get("workspaces") or {})
        users = dict(root.get("users") or {})
        existing_user = users.get(owner_uid)
        existing_user = dict(existing_user) if isinstance(existing_user, dict) else {}

        if not allow_any_authenticated:
            status = str(existing_user.get("status") or "active").strip().lower()
            if existing_user.get("suspended") is True or status in {"suspended", "disabled", "removed"}:
                raise BootstrapDenied("This account is suspended and cannot bootstrap an organization.")

            memberships = [
                workspace_id
                for workspace_id, workspace in workspaces.items()
                if isinstance(workspace, dict)
                and isinstance((workspace.get("members") or {}).get(owner_uid), dict)
            ]
            if memberships:
                raise BootstrapDenied("This account already has organization membership.")

            existing_employee_matches = []
            for workspace_id, workspace in workspaces.items():
                if not isinstance(workspace, dict):
                    continue
                for member_uid, member in (workspace.get("members") or {}).items():
                    if not isinstance(member, dict):
                        continue
                    old_user = users.get(member_uid)
                    old_email = (
                        str(old_user.get("email") or "").strip().lower()
                        if isinstance(old_user, dict)
                        else ""
                    )
                    if old_email and old_email == owner_email:
                        existing_employee_matches.append((workspace_id, member_uid))
            if existing_employee_matches:
                raise BootstrapDenied(
                    "This verified identity already belongs to an organization member."
                )

            for workspace in workspaces.values():
                if not isinstance(workspace, dict):
                    continue
                for invitation in (workspace.get("invitations") or {}).values():
                    if (
                        isinstance(invitation, dict)
                        and invitation.get("status") == "invited"
                        and str(invitation.get("email") or "").strip().lower() == owner_email
                    ):
                        expires_at = invitation.get("expires_at")
                        if expires_at is None or int(expires_at) > int(time.time() * 1000):
                            raise BootstrapDenied(
                                "A pending organization invitation must be accepted instead of creating an organization."
                            )

        principal_id = str(
            existing_user.get("principal_id")
            or existing_user.get("employee_id")
            or ""
        ).strip()
        if not principal_id:
            principal_id = f"emp_{uuid.uuid4().hex}"

        now = int(time.time() * 1000)
        roles = {
            rid: {
                "name": rid.title(),
                "permissions": sorted(perms),
                "system": True,
            }
            for rid, perms in DEFAULT_ROLES.items()
        }

        workspaces[workspace_id] = {
            "bootstrap": {
                "initialized": True,
                "owner_uid": owner_uid,
                "initialized_at": now,
            },
            "organization": {
                "organization_id": workspace_id,
                "name": organization_name,
                "status": "active",
                "created_at": now,
            },
            "roles": roles,
            "members": {
                owner_uid: {
                    "employee_id": principal_id,
                    "principal_id": principal_id,
                    "status": "active",
                    "roles": {"owner": True},
                    "identity_bindings": {
                        provider: [provider_subject],
                    },
                },
            },
            "resources": {},
            "invitations": {},
            "approved_employees": {},
            "delegations": {},
            "datasets": {},
            "working_copies": {},
        }

        updated_user = dict(existing_user)
        updated_user.update({
            "status": "active",
            "email": owner_email or str(existing_user.get("email") or "").strip().lower(),
            "employee_id": principal_id,
            "principal_id": principal_id,
            "linked_member_uid": owner_uid,
            "identity_provider": provider,
            "identity_provider_subject": provider_subject,
        })
        updated_user.setdefault("created_at", now)
        users[owner_uid] = updated_user

        root["workspaces"] = workspaces
        root["users"] = users
        return root

    try:
        result = root_ref.transaction(txn)
    except Exception as exc:
        raise BootstrapDenied("Organization bootstrap could not be completed.") from exc

    workspace = (result.get("workspaces") or {}).get(workspace_id)
    if not isinstance(workspace, dict):
        raise BootstrapDenied("Organization bootstrap could not be verified.")
    if (workspace.get("organization") or {}).get("name") != organization_name:
        raise BootstrapDenied("Organization bootstrap could not be verified.")

    return {
        "initialized": True,
        "owner_uid": owner_uid,
        "organization_id": workspace_id,
        "workspace_id": workspace_id,
        "membership_status": "active",
        "role_ids": ["owner"],
    }

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
        if isinstance(member, dict)
        and any(
            enabled and ROLE_ALIASES.get(role_id, role_id) == "organization_owner"
            for role_id, enabled in (member.get("roles") or {}).items()
        )
        and not ((_get(f"users/{uid}") or {}).get("suspended") is True)
    ]
    if target_uid in active_owners and len(active_owners) <= 1:
        raise PermissionDenied("The last active Owner cannot be removed or suspended.")

def mutate_role(target_uid: str, role_id: str, enabled: bool, actor_token: str, workspace_id: str):
    validate_id(target_uid, "user ID")
    validate_id(role_id, "role ID")
    claims = require_recent_auth(require_email_verified(verify_id_token(actor_token)))
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