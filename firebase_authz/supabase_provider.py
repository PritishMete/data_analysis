"""Server-side Supabase authorization persistence for organization bootstrap.

 This module accepts already verified provider claims and performs authorization
 against the existing PostgreSQL identity model.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text

from core.db import SessionLocal
from .service import AuthzError
from . import registration_diagnostics


def _id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def register_organization(claims: dict[str, Any], organization_name: str) -> dict[str, Any]:
    name = str(organization_name or "").strip()
    if not 1 <= len(name) <= 120 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Organization name must be between 1 and 120 characters.")

    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    if not uid:
        raise ValueError("Authenticated Firebase identity is required.")
    firebase = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(claims.get("provider") or firebase.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase.get("identities") if isinstance(firebase.get("identities"), dict) else {}
    subjects = identities.get(provider)
    subject = str(subjects[0]) if isinstance(subjects, list) and subjects else str(claims.get("sub") or uid)

    principal_id = _id("prn")
    organization_id = _id("org")
    workspace_id = organization_id
    location_id = _id("loc")
    employee_id = _id("emp")

    registration_diagnostics.stage("DB_TRANSACTION_START")
    with SessionLocal.begin() as db:
        existing = db.execute(
            text("SELECT principal_id FROM identity_bindings WHERE provider=:provider AND provider_subject=:subject"),
            {"provider": provider, "subject": subject},
        ).scalar_one_or_none()
        registration_diagnostics.stage("IDENTITY_LOOKUP_COMPLETE")
        if existing:
            principal_id = str(existing)
        else:
            db.execute(text("INSERT INTO principals(principal_id) VALUES (:id)"), {"id": principal_id})
            db.execute(text("""INSERT INTO identity_bindings(provider, provider_subject, firebase_uid, principal_id)
                             VALUES (:provider, :subject, :uid, :principal)"""),
                       {"provider": provider, "subject": subject, "uid": uid, "principal": principal_id})
        registration_diagnostics.stage("PRINCIPAL_SETUP_COMPLETE")

        db.execute(text("""INSERT INTO organizations(organization_id, name, created_by_principal_id)
                         VALUES (:id, :name, :principal)"""),
                   {"id": organization_id, "name": name, "principal": principal_id})
        registration_diagnostics.stage("ORGANIZATION_CREATED")
        db.execute(text("""INSERT INTO workspaces(workspace_id, organization_id)
                         VALUES (:workspace, :organization)"""),
                   {"workspace": workspace_id, "organization": organization_id})
        registration_diagnostics.stage("WORKSPACE_CREATED")
        db.execute(text("""INSERT INTO locations(location_id, organization_id, name)
                         VALUES (:location, :organization, :name)"""),
                   {"location": location_id, "organization": organization_id,
                    "name": "Main Location"})
        registration_diagnostics.stage("LOCATION_CREATED")
        db.execute(text("""INSERT INTO organization_members
                         (organization_id, workspace_id, principal_id, employee_id)
                         VALUES (:organization, :workspace, :principal, :employee)"""),
                   {"organization": organization_id, "workspace": workspace_id,
                    "principal": principal_id, "employee": employee_id})
        registration_diagnostics.stage("MEMBERSHIP_CREATED")
        db.execute(text("""INSERT INTO member_roles(organization_id, principal_id, role_id)
                         VALUES (:organization, :principal, 'organization_owner')"""),
                   {"organization": organization_id, "principal": principal_id})
        db.execute(text("""INSERT INTO audit_events
                         (event_id, organization_id, actor_principal_id, action, outcome)
                         VALUES (:event, :organization, :principal, 'organization.register', 'succeeded')"""),
                   {"event": _id("evt"), "organization": organization_id, "principal": principal_id})
        registration_diagnostics.stage("AUDIT_EVENT_CREATED")

    registration_diagnostics.stage("DB_COMMIT_COMPLETE")
    return {"initialized": True, "organization_id": organization_id,
            "workspace_id": workspace_id, "location_id": location_id,
            "membership_status": "active",
            "role_ids": ["organization_owner"]}


def _identity(claims: dict[str, Any]) -> tuple[str, str]:
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    firebase = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(claims.get("provider") or firebase.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase.get("identities") if isinstance(firebase.get("identities"), dict) else {}
    values = identities.get(provider)
    subject = str(values[0]) if isinstance(values, list) and values else str(claims.get("sub") or uid)
    return provider, subject


def _principal_for_claims(db, claims: dict[str, Any], organization_id: str | None = None):
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    provider, subject = _identity(claims)
    row = db.execute(text("""SELECT b.principal_id, m.employee_id, m.status
        FROM identity_bindings b
        LEFT JOIN organization_members m ON m.principal_id=b.principal_id
        WHERE ((b.provider=:provider AND b.provider_subject=:subject)
               OR (b.provider='firebase' AND b.firebase_uid=:uid))
          AND (:org IS NULL OR m.organization_id=:org)
          AND b.status='active'
        ORDER BY CASE WHEN m.status='active' THEN 0 ELSE 1 END"""),
                     {"uid": uid, "provider": provider, "subject": subject,
                      "org": organization_id}).mappings().first()
    return row


def _permission_for_principal(db, organization_id: str, principal_id: str, permission: str) -> bool:
    return db.execute(text("""SELECT 1 FROM member_roles mr
        JOIN role_permissions rp ON rp.role_id=mr.role_id
        WHERE mr.organization_id=:org AND mr.principal_id=:principal
          AND rp.permission_id=:permission"""),
                      {"org": organization_id, "principal": principal_id,
                       "permission": permission}).scalar_one_or_none() is not None


def create_invitation(claims: dict[str, Any], workspace_id: str, email: str,
                      employee_id: str, role_id: str, expires_at: int | None = None) -> dict[str, Any]:
    email = str(email or "").strip().lower()
    if "@" not in email or len(email) > 320:
        raise ValueError("Invalid invitation email.")
    role_id = {"owner": "organization_owner", "analyst": "employee", "viewer": "external_viewer"}.get(role_id, role_id)
    if role_id not in {"team_lead", "employee", "external_viewer"}:
        raise AuthzError("Invitations cannot directly assign Owner or Manager access.")
    expiry = datetime.fromtimestamp(expires_at / 1000, tz=timezone.utc) if expires_at is not None else None
    if expiry is not None and expiry <= datetime.now(timezone.utc):
        raise ValueError("Invitation expiry must be in the future.")
    invitation_id = _id("inv")
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or actor["status"] != "active" or not _permission_for_principal(db, workspace_id, actor["principal_id"], "invitation.manage"):
            raise AuthzError("Workspace authorization denied.")
        db.execute(text("""INSERT INTO invitations
            (invitation_id, organization_id, email, employee_id, role_id, status,
             expires_at, created_by_principal_id)
            VALUES (:id,:org,:email,:employee,:role,'invited',:expires,:creator)"""),
                   {"id": invitation_id, "org": workspace_id, "email": email,
                    "employee": employee_id, "role": role_id, "expires": expiry,
                    "creator": actor["principal_id"]})
    return {"invitation_id": invitation_id, "status": "invited"}


def pending_invitations(claims: dict[str, Any]) -> list[dict[str, Any]]:
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT invitation_id, organization_id, email, employee_id,
            role_id, status, expires_at FROM invitations
            WHERE lower(email)=:email AND status='invited'
              AND (expires_at IS NULL OR expires_at > now())"""), {"email": email}).mappings().all()
    return [dict(row) for row in rows]


def accept_invitation(claims: dict[str, Any], workspace_id: str, invitation_id: str) -> dict[str, Any]:
    provider, subject = _identity(claims)
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal.begin() as db:
        invitation = db.execute(text("""SELECT * FROM invitations
            WHERE invitation_id=:id AND organization_id=:org FOR UPDATE"""),
                                {"id": invitation_id, "org": workspace_id}).mappings().first()
        if not invitation or invitation["status"] != "invited":
            raise AuthzError("Invitation is no longer active.")
        if invitation["expires_at"] is not None and invitation["expires_at"] <= datetime.now(timezone.utc):
            raise AuthzError("Invitation has expired.")
        if invitation["email"].lower() != email:
            raise AuthzError("Invitation identity does not match the authenticated email.")
        existing = _principal_for_claims(db, claims, workspace_id)
        if existing and existing["status"] not in {"removed", "suspended"}:
            principal_id = existing["principal_id"]
        else:
            principal_id = _id("prn")
            db.execute(text("INSERT INTO principals(principal_id) VALUES (:id)"), {"id": principal_id})
            db.execute(text("""INSERT INTO identity_bindings(provider, provider_subject, firebase_uid, principal_id)
                VALUES (:provider,:subject,:uid,:principal)
                ON CONFLICT (provider, provider_subject) DO UPDATE SET firebase_uid=EXCLUDED.firebase_uid,
                status='active'"""), {"provider": provider, "subject": subject, "uid": uid, "principal": principal_id})
        db.execute(text("""INSERT INTO organization_members(organization_id, workspace_id, principal_id, employee_id, status)
            VALUES (:org,:workspace,:principal,:employee,'active')
            ON CONFLICT (organization_id, principal_id) DO UPDATE SET employee_id=EXCLUDED.employee_id,status='active'"""),
                   {"org": workspace_id, "workspace": workspace_id, "principal": principal_id,
                    "employee": invitation["employee_id"]})
        db.execute(text("""INSERT INTO member_roles(organization_id, principal_id, role_id)
            VALUES (:org,:principal,:role) ON CONFLICT DO NOTHING"""),
                   {"org": workspace_id, "principal": principal_id, "role": invitation["role_id"]})
        db.execute(text("""UPDATE invitations SET status='accepted', accepted_by_principal_id=:principal,
            accepted_at=now() WHERE invitation_id=:id"""),
                   {"id": invitation_id, "principal": principal_id})
    return {"accepted": True, "organization_id": workspace_id}


def set_membership_status(claims: dict[str, Any], workspace_id: str, target_uid: str, status: str) -> bool:
    if status not in {"approved", "active", "suspended", "removed"}:
        raise ValueError("Invalid membership status.")
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not actor or not target or not _permission_for_principal(db, workspace_id, actor["principal_id"], "membership.manage"):
            raise AuthzError("Workspace authorization denied.")
        if status in {"suspended", "removed"}:
            _guard_last_owner(db, workspace_id, target["principal_id"])
        db.execute(text("UPDATE organization_members SET status=:status WHERE organization_id=:org AND principal_id=:principal"),
                   {"status": status, "org": workspace_id, "principal": target["principal_id"]})
    return True


def _principal_for_uid(db, uid: str, organization_id: str):
    return db.execute(text("""SELECT b.principal_id, m.status FROM identity_bindings b
        JOIN organization_members m ON m.principal_id=b.principal_id
        WHERE b.firebase_uid=:uid AND m.organization_id=:org"""),
                      {"uid": uid, "org": organization_id}).mappings().first()


def _guard_last_owner(db, organization_id: str, principal_id: str):
    count = db.execute(text("""SELECT count(*) FROM organization_members m
        JOIN member_roles mr ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
        WHERE m.organization_id=:org AND m.status='active' AND mr.role_id='organization_owner'"""), {"org": organization_id}).scalar_one()
    is_owner = db.execute(text("SELECT 1 FROM member_roles WHERE organization_id=:org AND principal_id=:principal AND role_id='organization_owner'"),
                          {"org": organization_id, "principal": principal_id}).scalar_one_or_none()
    if is_owner and count <= 1:
        raise AuthzError("The last active Owner cannot be removed or suspended.")


def mutate_role(claims: dict[str, Any], workspace_id: str, target_uid: str,
                role_id: str, enabled: bool) -> bool:
    aliases = {"owner": "organization_owner", "analyst": "employee", "viewer": "external_viewer"}
    canonical = aliases.get(role_id, role_id)
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not actor or not target or not _permission_for_principal(db, workspace_id, actor["principal_id"], "roles.manage"):
            raise AuthzError("Workspace authorization denied.")
        role_exists = db.execute(text("SELECT 1 FROM roles WHERE role_id=:role"), {"role": canonical}).scalar_one_or_none()
        if not role_exists:
            raise AuthzError("Role is not part of the organization RBAC model.")
        if canonical == "organization_owner" and not enabled:
            _guard_last_owner(db, workspace_id, target["principal_id"])
        if enabled:
            db.execute(text("""INSERT INTO member_roles(organization_id, principal_id, role_id)
                VALUES (:org,:principal,:role) ON CONFLICT DO NOTHING"""),
                       {"org": workspace_id, "principal": target["principal_id"], "role": canonical})
        else:
            db.execute(text("DELETE FROM member_roles WHERE organization_id=:org AND principal_id=:principal AND role_id=:role"),
                       {"org": workspace_id, "principal": target["principal_id"], "role": canonical})
    return True


def upsert_role(claims: dict[str, Any], workspace_id: str, role_id: str,
                name: str, permissions: list[str]) -> bool:
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 100:
        raise ValueError("Invalid role name.")
    from .schema import clean_permissions
    permissions = clean_permissions(permissions)
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or not _permission_for_principal(db, workspace_id, actor["principal_id"], "roles.manage"):
            raise AuthzError("Workspace authorization denied.")
        role = db.execute(text("SELECT system FROM roles WHERE role_id=:role"), {"role": role_id}).scalar_one_or_none()
        if role is True:
            raise AuthzError("System roles cannot be overwritten.")
        db.execute(text("""INSERT INTO roles(role_id,name,system) VALUES (:role,:name,FALSE)
            ON CONFLICT (role_id) DO UPDATE SET name=EXCLUDED.name"""),
                   {"role": role_id, "name": name.strip()})
        db.execute(text("DELETE FROM role_permissions WHERE role_id=:role"), {"role": role_id})
        for permission in permissions:
            db.execute(text("INSERT INTO role_permissions(role_id,permission_id) VALUES (:role,:permission)"),
                       {"role": role_id, "permission": permission})
    return True


def _principal_for_uid_required(db, uid: str, organization_id: str):
    row = _principal_for_uid(db, uid, organization_id)
    if not row:
        raise AuthzError("User is not an organization member.")
    return row["principal_id"]


def set_approved_employee(claims: dict[str, Any], workspace_id: str,
                          target_uid: str, employee_id: str) -> bool:
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not actor or not target or actor["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        if not _permission_for_principal(db, workspace_id, actor["principal_id"], "membership.manage"):
            raise AuthzError("Workspace authorization denied.")
        db.execute(text("""INSERT INTO approved_employees
            (organization_id, workspace_id, employee_id, principal_id, status,
             approved_by_principal_id, approved_at)
            VALUES (:org,:workspace,:employee,:principal,'active',:actor,now())
            ON CONFLICT (organization_id, employee_id) DO UPDATE SET
              workspace_id=EXCLUDED.workspace_id, principal_id=EXCLUDED.principal_id,
              status='active', approved_by_principal_id=EXCLUDED.approved_by_principal_id,
              approved_at=now()"""),
                   {"org": workspace_id, "workspace": workspace_id, "employee": employee_id,
                    "principal": target["principal_id"], "actor": actor["principal_id"]})
    return True


def set_delegation(claims: dict[str, Any], workspace_id: str, team_lead_uid: str,
                   member_ids: list[str], dataset_ids: list[str], permissions: list[str],
                   expires_at: int | None) -> dict[str, Any]:
    allowed = {"dataset.view_original", "dataset.create_working_copy", "dataset.share"}
    if any(permission not in allowed for permission in permissions):
        raise ValueError("Delegation contains an unsupported capability.")
    expiry = datetime.fromtimestamp(expires_at / 1000, tz=timezone.utc) if expires_at is not None else None
    if expiry is not None and expiry <= datetime.now(timezone.utc):
        raise ValueError("Delegation expiry must be in the future.")
    delegation_id = _id("dlg")
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        lead = _principal_for_uid(db, team_lead_uid, workspace_id)
        if not actor or not lead or not _permission_for_principal(db, workspace_id, actor["principal_id"], "delegation.manage"):
            raise AuthzError("Workspace authorization denied.")
        if not db.execute(text("""SELECT 1 FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal AND role_id='team_lead'"""),
                          {"org": workspace_id, "principal": lead["principal_id"]}).scalar_one_or_none():
            raise AuthzError("Delegation target must have the Team Lead role.")
        member_principals = []
        for uid in sorted(set(member_ids)):
            principal = _principal_for_uid_required(db, uid, workspace_id)
            approved = db.execute(text("""SELECT 1 FROM approved_employees
                WHERE workspace_id=:workspace AND principal_id=:principal AND status='active'"""),
                                  {"workspace": workspace_id, "principal": principal}).scalar_one_or_none()
            if not approved:
                raise AuthzError("Delegation scope can contain only approved employees.")
            member_principals.append(principal)
        for dataset_id in sorted(set(dataset_ids)):
            exists = db.execute(text("""SELECT 1 FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:dataset AND status='active'"""),
                                {"org": workspace_id, "dataset": dataset_id}).scalar_one_or_none()
            if not exists:
                raise AuthzError("Dataset is not accessible.")
        db.execute(text("""INSERT INTO delegations
            (delegation_id, organization_id, workspace_id, team_lead_principal_id,
             member_principal_ids, dataset_ids, permissions, expires_at, status)
            VALUES (:id,:org,:workspace,:lead,CAST(:members AS jsonb),CAST(:datasets AS jsonb),
                    CAST(:permissions AS jsonb),:expires,'active')"""),
                   {"id": delegation_id, "org": workspace_id, "workspace": workspace_id,
                    "lead": lead["principal_id"], "members": json.dumps(member_principals),
                    "datasets": json.dumps(sorted(set(dataset_ids))),
                    "permissions": json.dumps(sorted(set(permissions))), "expires": expiry})
    return {"delegation_id": delegation_id}


def management_snapshot(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if "organization.view" not in context["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    org = workspace_id
    with SessionLocal() as db:
        members = db.execute(text("""SELECT b.firebase_uid AS uid, m.employee_id, m.status,
            COALESCE(array_agg(DISTINCT mr.role_id) FILTER (WHERE mr.role_id IS NOT NULL), ARRAY[]::text[]) AS role_ids
            FROM organization_members m JOIN identity_bindings b ON b.principal_id=m.principal_id
            LEFT JOIN member_roles mr ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
            WHERE m.organization_id=:org GROUP BY b.firebase_uid,m.employee_id,m.status"""), {"org": org}).mappings().all()
        datasets = db.execute(text("""SELECT d.dataset_id, d.protected_original, d.status,
            r.owner_principal_id FROM dataset_authorization d
            JOIN authorization_resources r ON r.organization_id=d.organization_id AND r.resource_id=d.dataset_id
            WHERE d.organization_id=:org AND d.status='active'"""), {"org": org}).mappings().all()
        working_copies = db.execute(text("""SELECT working_copy_id, source_dataset_id,
            source_version, version, status, created_by_principal_id
            FROM working_copy_authorization WHERE organization_id=:org AND status='active'"""),
                                   {"org": org}).mappings().all()
        approved = db.execute(text("""SELECT b.firebase_uid AS uid, a.employee_id, a.status
            FROM approved_employees a JOIN identity_bindings b ON b.principal_id=a.principal_id
            WHERE a.organization_id=:org AND a.status='active'"""), {"org": org}).mappings().all()
        delegations = db.execute(text("""SELECT delegation_id, team_lead_principal_id,
            member_principal_ids, dataset_ids, permissions, expires_at, status
            FROM delegations WHERE organization_id=:org"""), {"org": org}).mappings().all()
        audit = db.execute(text("""SELECT event_id, actor_principal_id, action, outcome,
            metadata, created_at FROM audit_events WHERE organization_id=:org
            ORDER BY created_at DESC LIMIT 100"""), {"org": org}).mappings().all()
        invitations = db.execute(text("""SELECT invitation_id,email,employee_id,role_id,status,expires_at
            FROM invitations WHERE organization_id=:org"""), {"org": org}).mappings().all()
    return {"organization_id": org, "workspace_id": workspace_id,
            "role_ids": context.get("role_ids", []),
            "members": [dict(row) for row in members], "datasets": [dict(row) for row in datasets],
            "working_copies": [dict(row) for row in working_copies],
            "invitations": [dict(row) for row in invitations],
            "approved_employees": [dict(row) for row in approved],
            "delegations": [dict(row) for row in delegations], "audit": [dict(row) for row in audit]}


def cleanup_account(claims: dict[str, Any], uid: str) -> dict[str, Any]:
    actor_uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    uid = str(uid or "").strip()
    if not actor_uid or actor_uid != uid:
        raise AuthzError("Account cleanup identity mismatch.")
    with SessionLocal.begin() as db:
        memberships = db.execute(text("""SELECT m.organization_id, m.principal_id
            FROM organization_members m JOIN identity_bindings b ON b.principal_id=m.principal_id
            WHERE b.firebase_uid=:uid AND m.status IN ('active','approved','suspended')"""),
                                  {"uid": uid}).mappings().all()
        affected = []
        for membership in memberships:
            org = membership["organization_id"]
            principal = membership["principal_id"]
            _guard_last_owner(db, org, principal)
            affected.append(org)
            db.execute(text("""UPDATE organization_members SET status='removed'
                WHERE organization_id=:org AND principal_id=:principal"""),
                       {"org": org, "principal": principal})
            db.execute(text("""UPDATE approved_employees SET status='revoked'
                WHERE organization_id=:org AND principal_id=:principal"""),
                       {"org": org, "principal": principal})
            db.execute(text("""UPDATE delegations SET status='revoked', updated_at=now()
                WHERE organization_id=:org AND (team_lead_principal_id=:principal
                   OR member_principal_ids @> CAST(:member AS jsonb))"""),
                       {"org": org, "principal": principal, "member": json.dumps([principal])})
            db.execute(text("""UPDATE invitations SET status='revoked'
                WHERE organization_id=:org AND lower(email)=lower(:email) AND status='invited'"""),
                       {"org": org, "email": str(claims.get("email") or "")})
            db.execute(text("""DELETE FROM resource_grants
                WHERE organization_id=:org AND principal_id=:principal"""),
                       {"org": org, "principal": principal})
            db.execute(text("""INSERT INTO audit_events
                (event_id, organization_id, actor_principal_id, action, outcome, metadata)
                VALUES (:event,:org,:principal,'account.cleanup','succeeded',CAST(:metadata AS jsonb))"""),
                       {"event": _id("evt"), "org": org, "principal": principal,
                        "metadata": json.dumps({"membership_revoked": True, "authorization_state_revoked": True})})
        db.execute(text("""UPDATE identity_bindings SET status='inactive', updated_at=now()
            WHERE firebase_uid=:uid"""), {"uid": uid})
    return {"revoked_workspaces": affected}


def authorization_context(claims: dict[str, Any], workspace_id: str | None = None) -> dict[str, Any]:
    provider, subject = _identity(claims)
    with SessionLocal() as db:
        row = db.execute(text("""SELECT p.principal_id, o.organization_id, o.name,
                    w.workspace_id, m.employee_id, m.status
                FROM identity_bindings b
                JOIN principals p ON p.principal_id = b.principal_id
                JOIN organization_members m ON m.principal_id = p.principal_id
                JOIN organizations o ON o.organization_id = m.organization_id
                JOIN workspaces w ON w.workspace_id = m.workspace_id
                WHERE b.provider=:provider AND b.provider_subject=:subject
                  AND (:workspace IS NULL OR w.workspace_id=:workspace)
                  AND b.status='active' AND m.status='active'"""),
                         {"provider": provider, "subject": subject, "workspace": workspace_id}).mappings().first()
        if not row:
            return {"membership_status": "none", "workspace_authorized": False,
                    "authorization_state": "no_organization_access", "principal_id": None,
                    "organization_id": None, "workspace_id": workspace_id,
                    "employee_id": None, "workspaces": [], "role_ids": [], "permissions": []}
        roles = db.execute(text("""SELECT mr.role_id FROM member_roles mr
            WHERE mr.organization_id=:organization AND mr.principal_id=:principal"""),
                           {"organization": row["organization_id"], "principal": row["principal_id"]}).scalars().all()
        permissions = db.execute(text("""SELECT DISTINCT rp.permission_id FROM role_permissions rp
            WHERE rp.role_id = ANY(:roles)"""), {"roles": list(roles)}).scalars().all() if roles else []
    return {"membership_status": "active", "workspace_authorized": True,
            "authorization_state": "active_identity", "principal_id": row["principal_id"],
            "organization_id": row["organization_id"], "workspace_id": row["workspace_id"],
            "employee_id": row["employee_id"], "role_ids": list(roles),
            "permissions": list(permissions), "organization_name": row["name"],
            "workspaces": [{"workspace_id": row["workspace_id"], "organization_id": row["organization_id"],
                            "employee_id": row["employee_id"], "membership_status": "active",
                            "role_ids": list(roles)}]}


def authorize(claims: dict[str, Any], workspace_id: str, action: str, resource_id: str | None = None) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if not context["workspace_authorized"] or action not in context["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    if resource_id:
        with SessionLocal() as db:
            resource = db.execute(text("SELECT 1 FROM authorization_resources WHERE organization_id=:org AND resource_id=:resource"),
                                   {"org": context["organization_id"], "resource": resource_id}).scalar_one_or_none()
            grant = db.execute(text("SELECT permissions FROM resource_grants WHERE organization_id=:org AND resource_id=:resource AND principal_id=:principal"),
                               {"org": context["organization_id"], "resource": resource_id, "principal": context["principal_id"]}).scalar_one_or_none()
        if not resource or action not in set(grant or []):
            raise AuthzError("Permission denied for this resource.")
    return {"authorized": True, "workspace_id": workspace_id, "action": action,
            "principal_id": context["principal_id"]}


def set_resource_grant(claims: dict[str, Any], workspace_id: str, resource_id: str,
                       target_uid: str, permissions: list[str],
                       required_permission: str | None = None) -> bool:
    actor = authorization_context(claims, workspace_id)
    capability = required_permission or "users.manage"
    if capability not in actor["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    from .schema import clean_permissions
    permissions = clean_permissions(permissions)
    with SessionLocal.begin() as db:
        target = db.execute(text("""SELECT b.principal_id FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE b.firebase_uid=:uid
              AND m.organization_id=:org AND m.status='active'"""),
                            {"uid": target_uid, "org": actor["organization_id"]}).scalar_one_or_none()
        if not target:
            raise AuthzError("Grant target is not a workspace member.")
        exists = db.execute(text("SELECT 1 FROM authorization_resources WHERE organization_id=:org AND resource_id=:resource"),
                            {"org": actor["organization_id"], "resource": resource_id}).scalar_one_or_none()
        if not exists:
            raise AuthzError("Resource is not accessible.")
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :resource, :principal, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions"""),
                   {"org": actor["organization_id"], "resource": resource_id,
                    "principal": target, "permissions": __import__('json').dumps(permissions)})
    return True


def register_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str | None,
                     owner_uid: str, protected: bool = True) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if "dataset.manage_acl" not in context["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    dataset_id = str(dataset_id or _id("ds"))
    with SessionLocal.begin() as db:
        owner = db.execute(text("""SELECT b.principal_id
            FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE b.firebase_uid=:uid AND m.organization_id=:org AND m.status='active'"""),
                           {"uid": owner_uid, "org": workspace_id}).scalar_one_or_none()
        if not owner:
            raise AuthzError("Dataset owner must be an active organization member.")
        db.execute(text("""INSERT INTO authorization_resources(organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :dataset, 'dataset', :owner) ON CONFLICT DO NOTHING"""),
                   {"org": workspace_id, "dataset": dataset_id, "owner": owner})
        db.execute(text("""INSERT INTO dataset_authorization(organization_id, dataset_id, owner_principal_id, protected_original)
            VALUES (:org, :dataset, :owner, :protected)
            ON CONFLICT (organization_id, dataset_id) DO UPDATE SET protected_original=EXCLUDED.protected_original"""),
                   {"org": workspace_id, "dataset": dataset_id, "owner": owner, "protected": protected})
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :dataset, :owner, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id) DO NOTHING"""),
                   {"org": workspace_id, "dataset": dataset_id, "owner": owner,
                    "permissions": '["dataset.view_original","dataset.create_working_copy","dataset.manage_acl"]'})
    return {"dataset_id": dataset_id, "organization_id": workspace_id}


def authorize_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str) -> dict[str, Any]:
    if not action.startswith("dataset."):
        raise ValueError("Dataset authorization requires a dataset capability.")
    result = authorize(claims, workspace_id, action, dataset_id)
    with SessionLocal() as db:
        protected = db.execute(text("SELECT protected_original FROM dataset_authorization WHERE organization_id=:org AND dataset_id=:dataset AND status='active'"),
                               {"org": workspace_id, "dataset": dataset_id}).scalar_one_or_none()
    if protected is None:
        raise AuthzError("Dataset is not accessible.")
    return {**result, "dataset_id": dataset_id, "protected_original": bool(protected)}


def set_dataset_grant(claims: dict[str, Any], workspace_id: str, dataset_id: str,
                      target_uid: str, permissions: list[str]) -> bool:
    allowed = {"dataset.view_original", "dataset.create_working_copy", "dataset.edit_working_copy", "dataset.share"}
    if any(p not in allowed for p in permissions):
        raise ValueError("Invalid dataset permission.")
    return set_resource_grant(
        claims, workspace_id, dataset_id, target_uid, permissions,
        required_permission="dataset.manage_acl",
    )


def create_working_copy(claims: dict[str, Any], workspace_id: str, dataset_id: str,
                        working_copy_id: str | None, source_version: str | None) -> dict[str, Any]:
    authorize_dataset(claims, workspace_id, dataset_id, "dataset.create_working_copy")
    context = authorization_context(claims, workspace_id)
    copy_id = working_copy_id or _id("wc")
    version = source_version or "1"
    with SessionLocal.begin() as db:
        db.execute(text("""INSERT INTO authorization_resources(organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :copy, 'working_copy', :principal)"""),
                   {"org": workspace_id, "copy": copy_id, "principal": context["principal_id"]})
        db.execute(text("""INSERT INTO working_copy_authorization
            (organization_id, working_copy_id, source_dataset_id, source_version, created_by_principal_id)
            VALUES (:org, :copy, :dataset, :version, :principal)"""),
                   {"org": workspace_id, "copy": copy_id, "dataset": dataset_id,
                    "version": version, "principal": context["principal_id"]})
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :copy, :principal, CAST(:permissions AS jsonb))"""),
                   {"org": workspace_id, "copy": copy_id, "principal": context["principal_id"],
                    "permissions": '["working_copy.view","working_copy.modify","working_copy.delete"]'})
    return {"working_copy_id": copy_id, "organization_id": workspace_id,
            "source_dataset_id": dataset_id, "source_version": version}


def authorize_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, action: str) -> dict[str, Any]:
    if action not in {"working_copy.view", "working_copy.modify", "working_copy.delete"}:
        raise ValueError("Invalid working copy action.")
    result = authorize(claims, workspace_id, action, working_copy_id)
    with SessionLocal() as db:
        row = db.execute(text("""SELECT source_dataset_id, source_version, version
            FROM working_copy_authorization WHERE organization_id=:org AND working_copy_id=:copy AND status='active'"""),
                         {"org": workspace_id, "copy": working_copy_id}).mappings().first()
    if not row:
        raise AuthzError("Working copy is not accessible.")
    return {**result, "working_copy_id": working_copy_id, "source_dataset_id": row["source_dataset_id"],
            "source_version": row["source_version"], "version": row["version"]}
