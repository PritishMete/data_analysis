"""Server-side Supabase authorization persistence for organization bootstrap.

 This module accepts already verified provider claims and performs authorization
 against the existing PostgreSQL identity model.
"""
from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text

from core.db import SessionLocal
from .service import AuthzError
from . import registration_diagnostics
from .profile_validation import normalize_phone_submission, validate_profile_fields
from .supabase_admin import find_user_by_email, invite_user_by_email


logger = logging.getLogger(__name__)


class OrganizationRegistrationConflict(AuthzError):
    """The authenticated identity is already onboarded for this product model."""


def _id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _normalize_phone(value: str) -> str:
    import re
    normalized = re.sub(r"[\s\-().]", "", str(value or "").strip())
    if not re.fullmatch(r"\+[1-9]\d{7,14}", normalized):
        raise ValueError("Phone number must be a valid E.164 number.")
    return normalized


def _clean_profile_text(value: str | None, field: str, max_length: int = 200) -> str:
    text_value = str(value or "").strip()
    if not text_value or len(text_value) > max_length or any(
        ord(char) < 32 or ord(char) == 127 for char in text_value
    ):
        raise ValueError(f"{field} is required and must be at most {max_length} characters.")
    return text_value


def _auth_timestamp(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _allocate_employee_id(db, organization_id: str) -> str:
    """Atomically issue the next organization-scoped Employee ID."""
    issued = db.execute(
        text(
            """INSERT INTO organization_employee_id_counters
                   (organization_id, last_issued)
               VALUES (:organization, 1)
               ON CONFLICT (organization_id) DO UPDATE
                   SET last_issued =
                       organization_employee_id_counters.last_issued + 1,
                       updated_at = now()
               RETURNING last_issued"""
        ),
        {"organization": organization_id},
    ).scalar_one()
    return f"EMP{int(issued):03d}"


def register_organization(
    claims: dict[str, Any],
    organization_name: str,
    branch_name: str,
    branch_identifier: str,
    *,
    full_name: str,
    phone: str,
    address_line1: str,
    state: str,
    postal_code: str,
    country: str,
    id_proof_type: str,
    id_proof_number: str,
    address_line2: str = "",
    city: str = "",
    country_code: str | None = None,
    state_code: str | None = None,
    phone_country_calling_code: str | None = None,
    phone_national_number: str | None = None,
) -> dict[str, Any]:
    name = str(organization_name or "").strip()
    if not 1 <= len(name) <= 120 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Organization name must be between 1 and 120 characters.")

    branch = str(branch_name or "").strip()
    if not 1 <= len(branch) <= 160 or any(ord(c) < 32 or ord(c) == 127 for c in branch):
        raise ValueError("Branch name must be between 1 and 160 characters.")

    branch_id = str(branch_identifier or "")
    if not branch_id:
        raise ValueError("Branch identifier is required.")

    profile_name = _clean_profile_text(full_name, "Full name", 160)
    profile_fields = validate_profile_fields(
        full_name=profile_name,
        country_code=country_code,
        country=country,
        state_code=state_code,
        state=state,
        address_line1=address_line1,
        address_line2=address_line2,
        postal_code=postal_code,
        id_proof_type=id_proof_type,
        id_proof_number=id_proof_number,
        phone=phone,
        phone_country_calling_code=phone_country_calling_code,
        phone_national_number=phone_national_number,
    )
    profile_phone = profile_fields["phone_e164"]
    address1 = profile_fields["address_line1"]
    address2 = profile_fields["address_line2"]
    profile_city = ""
    profile_state = profile_fields["state"]
    profile_postal = profile_fields["postal_code"]
    profile_country = profile_fields["country"]
    profile_country_code = profile_fields["country_code"]
    profile_state_code = profile_fields["state_code"]
    proof_type = profile_fields["id_proof_type"]
    proof_number = profile_fields["id_proof_number"]

    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    if not uid:
        raise ValueError("Authenticated identity is required.")

    if not bool(claims.get("email_verified")):
        raise AuthzError("Verified email is required to create an organization.")

    authoritative_email = str(claims.get("email") or "").strip().lower()
    if not authoritative_email or "@" not in authoritative_email:
        raise AuthzError("A verified authenticated email is required to create an organization.")

    # Phone is profile data only. Validate/store it in E.164 format, but do not
    # require Supabase phone authentication or phone verification during onboarding.
    confirmed_phone_at = None

    firebase = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(
        claims.get("provider")
        or firebase.get("sign_in_provider")
        or "firebase"
    ).strip().lower()
    identities = firebase.get("identities") if isinstance(firebase.get("identities"), dict) else {}
    subjects = identities.get(provider)
    subject = (
        str(subjects[0])
        if isinstance(subjects, list) and subjects
        else str(claims.get("sub") or uid)
    )

    principal_id = _id("prn")
    organization_id = _id("org")
    workspace_id = organization_id
    location_id = _id("loc")
    assignment_id = _id("asg")

    registration_diagnostics.stage("DB_TRANSACTION_START")
    with SessionLocal.begin() as db:
        existing = db.execute(
            text(
                "SELECT principal_id FROM identity_bindings "
                "WHERE provider=:provider AND provider_subject=:subject"
            ),
            {"provider": provider, "subject": subject},
        ).scalar_one_or_none()
        registration_diagnostics.stage("IDENTITY_LOOKUP_COMPLETE")
        if existing:
            principal_id = str(existing)
        else:
            db.execute(
                text("INSERT INTO principals(principal_id) VALUES (:id)"),
                {"id": principal_id},
            )
            db.execute(
                text(
                    """INSERT INTO identity_bindings(provider, provider_subject, firebase_uid, principal_id)
                    VALUES (:provider, :subject, :uid, :principal)"""
                ),
                {
                    "provider": provider,
                    "subject": subject,
                    "uid": uid,
                    "principal": principal_id,
                },
            )
        registration_diagnostics.stage("PRINCIPAL_SETUP_COMPLETE")

        active_membership = db.execute(
            text(
                """SELECT organization_id, workspace_id
                FROM organization_members
                WHERE principal_id=:principal AND status='active'
                ORDER BY organization_id
                LIMIT 1"""
            ),
            {"principal": principal_id},
        ).mappings().first()
        if active_membership:
            raise OrganizationRegistrationConflict(
                "This account already has an active organization membership. "
                "Open the existing organization instead of registering another one."
            )
        registration_diagnostics.stage("ACTIVE_MEMBERSHIP_CHECK_COMPLETE")

        db.execute(
            text(
                """INSERT INTO organizations(organization_id, name, created_by_principal_id)
                VALUES (:id, :name, :principal)"""
            ),
            {"id": organization_id, "name": name, "principal": principal_id},
        )
        registration_diagnostics.stage("ORGANIZATION_CREATED")
        db.execute(
            text(
                """INSERT INTO workspaces(workspace_id, organization_id)
                VALUES (:workspace, :organization)"""
            ),
            {"workspace": workspace_id, "organization": organization_id},
        )
        registration_diagnostics.stage("WORKSPACE_CREATED")

        duplicate_branch = db.execute(
            text(
                "SELECT 1 FROM locations "
                "WHERE lower(branch_identifier)=lower(:identifier) AND status='active' LIMIT 1"
            ),
            {"identifier": branch_id},
        ).scalar_one_or_none()
        if duplicate_branch:
            raise ValueError("Branch identifier is already in use by an active branch.")

        db.execute(
            text(
                """INSERT INTO locations(location_id, organization_id, name, branch_identifier)
                VALUES (:location, :organization, :name, :branch_identifier)"""
            ),
            {
                "location": location_id,
                "organization": organization_id,
                "name": branch,
                "branch_identifier": branch_id,
            },
        )
        registration_diagnostics.stage("LOCATION_CREATED")
        employee = _allocate_employee_id(db, organization_id)

        db.execute(
            text(
                """INSERT INTO organization_members
                (organization_id, workspace_id, principal_id, employee_id)
                VALUES (:organization, :workspace, :principal, :employee)"""
            ),
            {
                "organization": organization_id,
                "workspace": workspace_id,
                "principal": principal_id,
                "employee": employee,
            },
        )
        registration_diagnostics.stage("MEMBERSHIP_CREATED")

        db.execute(
            text(
                """INSERT INTO member_roles(organization_id, principal_id, role_id)
                VALUES (:organization, :principal, 'branch_head')"""
            ),
            {"organization": organization_id, "principal": principal_id},
        )

        db.execute(
            text(
                """INSERT INTO organizational_assignments
                (assignment_id, organization_id, principal_id, location_id,
                 role_id, section_id, reports_to_assignment_id, status)
                VALUES (:assignment, :organization, :principal, :location,
                        'branch_head', NULL, NULL, 'active')"""
            ),
            {
                "assignment": assignment_id,
                "organization": organization_id,
                "principal": principal_id,
                "location": location_id,
            },
        )
        registration_diagnostics.stage("OWNER_ASSIGNMENT_CREATED")

        email_verified_at = _auth_timestamp(claims.get("email_confirmed_at"))
        if email_verified_at is None:
            email_verified_at = datetime.now(timezone.utc)
        db.execute(
            text(
                """INSERT INTO organization_member_profiles
                (organization_id, principal_id, full_name, email, email_verified_at,
                 phone_e164, phone_verified_at, address_line1, address_line2,
                 city, state, state_code, postal_code, country, country_code,
                 id_proof_type, id_proof_number, id_proof_provided_at)
                VALUES
                (:organization, :principal, :full_name, :email, :email_verified_at,
                 :phone, :phone_verified_at, :address_line1, :address_line2,
                 :city, :state, :state_code, :postal_code, :country, :country_code,
                 :id_proof_type, :id_proof_number, now())"""
            ),
            {
                "organization": organization_id,
                "principal": principal_id,
                "full_name": profile_name,
                "email": authoritative_email,
                "email_verified_at": email_verified_at,
                "phone": profile_phone,
                "phone_verified_at": confirmed_phone_at,
                "address_line1": address1,
                "address_line2": address2 or None,
                "city": profile_city,
                "state": profile_state,
                "state_code": profile_state_code,
                "postal_code": profile_postal,
                "country": profile_country,
                "country_code": profile_country_code,
                "id_proof_type": proof_type,
                "id_proof_number": proof_number,
            },
        )
        registration_diagnostics.stage("PROFILE_CREATED")

        db.execute(
            text(
                """INSERT INTO audit_events
                (event_id, organization_id, actor_principal_id, action, outcome, metadata)
                VALUES (:event, :organization, :principal, 'organization.register', 'succeeded',
                        CAST(:metadata AS jsonb))"""
            ),
            {
                "event": _id("evt"),
                "organization": organization_id,
                "principal": principal_id,
                "metadata": json.dumps(
                    {
                        "location_id": location_id,
                        "assignment_id": assignment_id,
                        "employee_id": employee,
                    }
                ),
            },
        )
        db.execute(
            text(
                """INSERT INTO audit_events
                (event_id, organization_id, actor_principal_id, action, outcome, metadata)
                VALUES (:event, :organization, :principal, 'people.profile.created', 'succeeded',
                        CAST(:metadata AS jsonb))"""
            ),
            {
                "event": _id("evt"),
                "organization": organization_id,
                "principal": principal_id,
                "metadata": json.dumps(
                    {
                        "assignment_id": assignment_id,
                        "employee_id": employee,
                    }
                ),
            },
        )
        registration_diagnostics.stage("AUDIT_EVENT_CREATED")
        registration_diagnostics.stage("DB_COMMIT_COMPLETE")

    return {
        "initialized": True,
        "organization_id": organization_id,
        "workspace_id": workspace_id,
        "location_id": location_id,
        "branch_identifier": branch_id,
        "membership_status": "active",
        "role_ids": ["branch_head"],
        "employee_id": employee,
        "branch_head_assignment_id": assignment_id,
        "branch_head": {
            "principal_id": principal_id,
            "employee_id": employee,
            "full_name": profile_name,
        },
    }

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
          AND (CAST(:org AS TEXT) IS NULL OR m.organization_id=CAST(:org AS TEXT))
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
                      role_id: str, expires_at: int | None = None) -> dict[str, Any]:
    email = str(email or "").strip().lower()
    if "@" not in email or len(email) > 320:
        raise ValueError("Invalid invitation email.")
    role_id = {"owner": "organization_owner", "analyst": "employee", "viewer": "external_viewer"}.get(role_id, role_id)
    invitation_roles = {
        "manager", "team_lead", "employee", "external_viewer",
        "data_analyst", "senior_data_analyst", "business_analyst",
        "data_scientist", "data_engineer", "ml_engineer",
        "analytics_engineer", "bi_developer", "data_architect",
        "data_quality_analyst", "data_governance_analyst",
    }
    if role_id not in invitation_roles:
        raise AuthzError("Unsupported invitation role.")
    expiry = datetime.fromtimestamp(expires_at / 1000, tz=timezone.utc) if expires_at is not None else None
    if expiry is not None and expiry <= datetime.now(timezone.utc):
        raise ValueError("Invitation expiry must be in the future.")

    with SessionLocal() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or actor["status"] != "active" or not _permission_for_principal(db, workspace_id, actor["principal_id"], "invitation.manage"):
            raise AuthzError("Workspace authorization denied.")
        if role_id == "manager":
            is_owner = db.execute(text("""SELECT 1 FROM member_roles
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='organization_owner'"""),
                {"org": workspace_id, "principal": actor["principal_id"]}).scalar_one_or_none()
            if is_owner is None:
                raise AuthzError("Only the Organization Owner can invite a Manager.")

    invitation_id = _id("inv")
    redirect_to = os.environ.get("INSIGHTFLOW_EMPLOYEE_INVITE_REDIRECT", "https://pritishmete.github.io/data_analysis/employee-invite").strip()
    if not redirect_to:
        raise AuthzError("Employee invitation redirect is not configured.")

    auth_user_id = ""
    delivery_status = "initiated"
    password_setup_required = True
    try:
        invited = invite_user_by_email(email, redirect_to)
        auth_user_id = invited["user_id"]
        if not auth_user_id:
            raise RuntimeError("Supabase Auth returned no user ID.")
    except Exception as invite_error:
        try:
            existing = find_user_by_email(email)
        except Exception as lookup_error:
            raise AuthzError("Employee invitation email could not be initiated. The server-side Supabase Auth Admin credential is missing or invalid.") from lookup_error
        if not existing:
            raise AuthzError("Employee invitation email could not be initiated. No invitation record was created.") from invite_error
        if not existing["email_confirmed"]:
            raise AuthzError("This email already has an unconfirmed Auth account. Complete its existing confirmation flow rather than creating a duplicate account.") from invite_error
        auth_user_id = existing["user_id"]
        delivery_status = "existing_account"
        password_setup_required = False

    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or actor["status"] != "active" or not _permission_for_principal(db, workspace_id, actor["principal_id"], "invitation.manage"):
            raise AuthzError("Workspace authorization denied.")
        db.execute(text("""INSERT INTO invitations
            (invitation_id, organization_id, email, role_id, status,
             expires_at, created_by_principal_id, auth_user_id,
             email_delivery_status, email_delivery_started_at)
            VALUES (:id,:org,:email,:role,'invited',:expires,:creator,:auth_user,
                    :delivery_status, CASE WHEN :delivery_status='initiated' THEN now() ELSE NULL END)"""),
                   {"id": invitation_id, "org": workspace_id, "email": email,
                    "role": role_id, "expires": expiry, "creator": actor["principal_id"],
                    "auth_user": auth_user_id, "delivery_status": delivery_status})
    return {"invitation_id": invitation_id, "status": "invited",
            "email_delivery_status": delivery_status,
            "password_setup_required": password_setup_required}

def pending_invitations(claims: dict[str, Any]) -> list[dict[str, Any]]:
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT invitation_id, organization_id, email, employee_id,
            role_id, status, expires_at, auth_user_id, email_delivery_status, password_setup_at FROM invitations
            WHERE lower(email)=:email AND status='invited'
              AND (expires_at IS NULL OR expires_at > now())"""), {"email": email}).mappings().all()
    return [dict(row) for row in rows]


def accept_invitation(claims: dict[str, Any], workspace_id: str | None, invitation_id: str) -> dict[str, Any]:
    provider, subject = _identity(claims)
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal.begin() as db:
        invitation = db.execute(
            text("""SELECT * FROM invitations
                    WHERE invitation_id=:id
                      AND (:org IS NULL OR organization_id=:org)
                    FOR UPDATE"""),
            {"id": invitation_id, "org": workspace_id},
        ).mappings().first()
        if not invitation or invitation["status"] != "invited":
            raise AuthzError("Invitation is no longer active.")
        if invitation["expires_at"] is not None and invitation["expires_at"] <= datetime.now(timezone.utc):
            raise AuthzError("Invitation has expired.")
        if invitation["email"].lower() != email:
            raise AuthzError("Invitation identity does not match the authenticated email.")
        workspace_id = str(invitation["organization_id"])

        identity = db.execute(
            text("""SELECT principal_id FROM identity_bindings
                    WHERE provider=:provider AND provider_subject=:subject
                      AND status='active'
                    FOR UPDATE"""),
            {"provider": provider, "subject": subject},
        ).scalar_one_or_none()

        principal_id = str(identity) if identity else None
        if principal_id:
            active_membership = db.execute(
                text("""SELECT organization_id FROM organization_members
                        WHERE principal_id=:principal AND status='active'
                        ORDER BY organization_id
                        LIMIT 1
                        FOR UPDATE"""),
                {"principal": principal_id},
            ).scalar_one_or_none()
            if active_membership and str(active_membership) != str(workspace_id):
                raise AuthzError(
                    "This account already has an active organization membership."
                )
        else:
            principal_id = _id("prn")
            db.execute(text("INSERT INTO principals(principal_id) VALUES (:id)"), {"id": principal_id})
            db.execute(text("""INSERT INTO identity_bindings(provider, provider_subject, firebase_uid, principal_id)
                VALUES (:provider,:subject,:uid,:principal)"""),
                       {"provider": provider, "subject": subject, "uid": uid, "principal": principal_id})

        existing_member = db.execute(
            text("""SELECT employee_id FROM organization_members
                    WHERE organization_id=:org AND principal_id=:principal
                    FOR UPDATE"""),
            {"org": workspace_id, "principal": principal_id},
        ).mappings().first()
        employee_id = (
            str(existing_member["employee_id"])
            if existing_member and existing_member["employee_id"]
            else _allocate_employee_id(db, workspace_id)
        )
        db.execute(text("""INSERT INTO organization_members(organization_id, workspace_id, principal_id, employee_id, status)
            VALUES (:org,:workspace,:principal,:employee,'active')
            ON CONFLICT (organization_id, principal_id) DO UPDATE
              SET employee_id=EXCLUDED.employee_id,status='active'"""),
                   {"org": workspace_id, "workspace": workspace_id, "principal": principal_id,
                    "employee": employee_id})
        db.execute(text("""INSERT INTO member_roles(organization_id, principal_id, role_id)
            VALUES (:org,:principal,:role) ON CONFLICT DO NOTHING"""),
                   {"org": workspace_id, "principal": principal_id, "role": invitation["role_id"]})
        db.execute(text("""UPDATE invitations SET status='accepted', accepted_by_principal_id=:principal,
            accepted_at=now() WHERE invitation_id=:id"""),
                   {"id": invitation_id, "principal": principal_id})
    return {"accepted": True, "organization_id": workspace_id, "employee_id": employee_id}


def mark_invitation_password_setup(claims: dict[str, Any], invitation_id: str) -> dict[str, Any]:
    email = str(claims.get("email") or "").strip().lower()
    if not bool(claims.get("email_verified")):
        raise AuthzError("Verified email is required.")
    with SessionLocal.begin() as db:
        invitation = db.execute(
            text("""SELECT invitation_id, organization_id, email, status, expires_at
                    FROM invitations WHERE invitation_id=:id FOR UPDATE"""),
            {"id": invitation_id},
        ).mappings().first()
        if not invitation or invitation["status"] != "invited":
            raise AuthzError("Invitation is no longer active.")
        if invitation["expires_at"] is not None and invitation["expires_at"] <= datetime.now(timezone.utc):
            raise AuthzError("Invitation has expired.")
        if invitation["email"].lower() != email:
            raise AuthzError("Invitation identity does not match the authenticated email.")
        db.execute(
            text("""UPDATE invitations SET password_setup_at=now()
                    WHERE invitation_id=:id"""),
            {"id": invitation_id},
        )
    return {"password_setup": True, "organization_id": str(invitation["organization_id"])}

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
    org = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    with SessionLocal() as db:
        members = db.execute(text("""SELECT b.firebase_uid AS uid, m.employee_id, m.status,
            COALESCE(array_agg(DISTINCT mr.role_id) FILTER (WHERE mr.role_id IS NOT NULL), ARRAY[]::text[]) AS role_ids
            FROM organization_members m JOIN identity_bindings b ON b.principal_id=m.principal_id
            LEFT JOIN member_roles mr ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
            WHERE m.organization_id=:org GROUP BY b.firebase_uid,m.employee_id,m.status"""), {"org": org}).mappings().all()
        datasets = db.execute(text("""SELECT da.dataset_id, da.protected_original,
            da.status AS authorization_status, r.owner_principal_id,
            ds.dataset_name, ds.original_filename, ds.row_count, ds.column_count,
            ds.current_version_id AS current_version, ds.version_number,
            ds.file_size, ds.uploaded_by, ds.created_at, ds.status AS dataset_status
            FROM dataset_authorization da
            JOIN authorization_resources r
              ON r.organization_id=da.organization_id AND r.resource_id=da.dataset_id
            LEFT JOIN datasets ds
              ON ds.organization_id=da.organization_id AND ds.dataset_id=da.dataset_id
            WHERE da.organization_id=:org AND da.status='active'"""), {"org": org}).mappings().all()
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
    return {"organization_id": org, "workspace_id": resolved_workspace_id,
            "role_ids": context.get("role_ids", []),
            "members": [dict(row) for row in members],
            "datasets": [
                {
                    **dict(row),
                    "status": row["dataset_status"] or row["authorization_status"],
                    "display_name": row["dataset_name"] or row["original_filename"] or row["dataset_id"],
                    "uploaded_by_uid": row["uploaded_by"],
                    "version": row["version_number"],
                }
                for row in datasets
            ],
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
    """Resolve identity -> principal -> active membership -> organization/workspace.

    A supplied workspace is only a selector. It can never create or override
    membership context. When no selector is supplied, return every active
    workspace so callers can deterministically recover a unique context.
    """
    provider, subject = _identity(claims)
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT p.principal_id, o.organization_id, o.name,
                    w.workspace_id, m.employee_id, m.status
                FROM identity_bindings b
                JOIN principals p ON p.principal_id = b.principal_id
                JOIN organization_members m ON m.principal_id = p.principal_id
                JOIN organizations o ON o.organization_id = m.organization_id
                JOIN workspaces w ON w.workspace_id = m.workspace_id
                WHERE b.provider=:provider AND b.provider_subject=:subject
                  AND (CAST(:workspace AS TEXT) IS NULL OR w.workspace_id=CAST(:workspace AS TEXT))
                  AND b.status='active' AND m.status='active'
                  AND o.status='active' AND w.status='active'
                ORDER BY w.workspace_id"""),
                         {"provider": provider, "subject": subject, "workspace": workspace_id}).mappings().all()
        if not rows:
            return {"membership_status": "none", "workspace_authorized": False,
                    "authorization_state": "no_organization_access", "principal_id": None,
                    "organization_id": None, "workspace_id": workspace_id,
                    "employee_id": None, "workspaces": [], "role_ids": [], "permissions": []}

        # A selected workspace must resolve to exactly one active membership.
        if workspace_id is not None and len(rows) != 1:
            return {"membership_status": "none", "workspace_authorized": False,
                    "authorization_state": "workspace_not_authorized", "principal_id": str(rows[0]["principal_id"]),
                    "organization_id": None, "workspace_id": workspace_id,
                    "employee_id": None, "workspaces": [
                        {"workspace_id": str(row["workspace_id"]),
                         "organization_id": str(row["organization_id"]),
                         "employee_id": row["employee_id"],
                         "membership_status": "active"}
                        for row in rows
                    ], "role_ids": [], "permissions": []}

        selected = rows[0]
        profile_row = db.execute(text("""
            SELECT full_name, email, email_verified_at, phone_e164, phone_verified_at,
                   address_line1, state, country, postal_code, id_proof_type, id_proof_number
            FROM organization_member_profiles
            WHERE organization_id=:org AND principal_id=:principal
        """), {
            "org": selected["organization_id"],
            "principal": selected["principal_id"],
        }).mappings().first()
        authoritative_email_verified = bool(claims.get("email_verified"))
        profile_complete = bool(profile_row) and all([
            str(profile_row["full_name"] or "").strip(),
            str(selected["employee_id"] or "").strip(),
            str(profile_row["email"] or "").strip(),
            profile_row["email_verified_at"] is not None,
            authoritative_email_verified,
            str(profile_row["phone_e164"] or "").strip(),
            str(profile_row["address_line1"] or "").strip(),
            str(profile_row["state"] or "").strip(),
            str(profile_row["country"] or "").strip(),
            str(profile_row["postal_code"] or "").strip(),
            str(profile_row["id_proof_type"] or "").strip(),
            str(profile_row["id_proof_number"] or "").strip(),
        ])
        roles = db.execute(text("""SELECT mr.role_id FROM member_roles mr
            WHERE mr.organization_id=:organization AND mr.principal_id=:principal"""),
                           {"organization": selected["organization_id"], "principal": selected["principal_id"]}).scalars().all()
        permissions = db.execute(text("""SELECT DISTINCT rp.permission_id FROM role_permissions rp
            WHERE rp.role_id = ANY(:roles)"""), {"roles": list(roles)}).scalars().all() if roles else []

        workspaces = []
        for row in rows:
            workspaces.append({
                "workspace_id": str(row["workspace_id"]),
                "organization_id": str(row["organization_id"]),
                "employee_id": row["employee_id"],
                "membership_status": "active",
                "role_ids": list(roles) if row["organization_id"] == selected["organization_id"] else [],
            })

    return {"membership_status": "active", "workspace_authorized": True,
            "authorization_state": "active_identity", "principal_id": selected["principal_id"],
            "organization_id": selected["organization_id"], "workspace_id": selected["workspace_id"],
            "employee_id": selected["employee_id"], "role_ids": list(roles),
            "permissions": list(permissions), "organization_name": selected["name"],
            "profile_complete": profile_complete,
            "workspaces": workspaces}

def authorize(claims: dict[str, Any], workspace_id: str, action: str, resource_id: str | None = None) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if not context["workspace_authorized"] or action not in context["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    resolved_workspace_id = str(context["workspace_id"])
    organization_id = str(context["organization_id"])
    if resource_id:
        with SessionLocal() as db:
            resource = db.execute(
                text("""SELECT resource_type, owner_principal_id
                        FROM authorization_resources
                        WHERE organization_id=:org AND resource_id=:resource"""),
                {"org": organization_id, "resource": resource_id},
            ).mappings().first()
            grant = db.execute(
                text("""SELECT permissions
                        FROM resource_grants
                        WHERE organization_id=:org
                          AND resource_id=:resource
                          AND principal_id=:principal"""),
                {"org": organization_id, "resource": resource_id,
                 "principal": context["principal_id"]},
            ).scalar_one_or_none()
        if not resource:
            raise AuthzError("Resource is not accessible.")
        if action not in set(grant or []):
            raise AuthzError("Permission denied for this resource.")
    return {"authorized": True, "workspace_id": resolved_workspace_id, "organization_id": organization_id,
            "action": action, "principal_id": context["principal_id"]}


def set_resource_grant(claims: dict[str, Any], workspace_id: str, resource_id: str,
                       target_uid: str, permissions: list[str],
                       required_permission: str | None = None) -> bool:
    actor = authorization_context(claims, workspace_id)
    capability = required_permission or "users.manage"
    if capability not in actor["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    from .schema import clean_permissions
    permissions = clean_permissions(permissions)
    organization_id = str(actor["organization_id"])
    with SessionLocal.begin() as db:
        target = db.execute(text("""SELECT b.principal_id FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE ((b.provider='supabase' AND b.provider_subject=:uid)
                OR (b.provider='firebase' AND b.firebase_uid=:uid))
              AND m.organization_id=:org AND m.status='active'
              AND b.status='active'"""),
                            {"uid": target_uid, "org": organization_id}).scalar_one_or_none()
        if not target:
            raise AuthzError("Grant target is not a workspace member.")
        exists = db.execute(text("SELECT 1 FROM authorization_resources WHERE organization_id=:org AND resource_id=:resource"),
                            {"org": organization_id, "resource": resource_id}).scalar_one_or_none()
        if not exists:
            raise AuthzError("Resource is not accessible.")
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :resource, :principal, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions"""),
                   {"org": organization_id, "resource": resource_id,
                    "principal": target, "permissions": __import__('json').dumps(permissions)})
    return True


def register_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str | None,
                     owner_uid: str, protected: bool = True) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if "dataset.manage_acl" not in context["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    organization_id = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    dataset_id = str(dataset_id or _id("ds"))
    provider, subject = _identity(claims)
    with SessionLocal.begin() as db:
        owner = db.execute(text("""SELECT b.principal_id
            FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE ((b.provider=:provider AND b.provider_subject=:owner_uid)
                OR (b.provider='firebase' AND b.firebase_uid=:owner_uid))
              AND m.organization_id=:org AND m.workspace_id=:workspace
              AND m.status='active' AND b.status='active'"""),
                           {"provider": provider, "owner_uid": str(owner_uid),
                            "org": organization_id, "workspace": resolved_workspace_id}).scalar_one_or_none()
        if not owner:
            raise AuthzError("Dataset owner must be an active organization member.")
        db.execute(text("""INSERT INTO authorization_resources(organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :dataset, 'dataset', :owner)
            ON CONFLICT (organization_id, resource_id)
            DO UPDATE SET resource_type=EXCLUDED.resource_type, owner_principal_id=EXCLUDED.owner_principal_id"""),
                   {"org": organization_id, "dataset": dataset_id, "owner": owner})
        db.execute(text("""INSERT INTO dataset_authorization(organization_id, dataset_id, owner_principal_id, protected_original)
            VALUES (:org, :dataset, :owner, :protected)
            ON CONFLICT (organization_id, dataset_id)
            DO UPDATE SET owner_principal_id=EXCLUDED.owner_principal_id,
                          protected_original=EXCLUDED.protected_original,
                          status='active'"""),
                   {"org": organization_id, "dataset": dataset_id, "owner": owner, "protected": protected})
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :dataset, :owner, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions"""),
                   {"org": organization_id, "dataset": dataset_id, "owner": owner,
                    "permissions": '["dataset.view_original","dataset.create_working_copy","dataset.manage_acl"]'})
    return {"dataset_id": dataset_id, "organization_id": organization_id, "workspace_id": resolved_workspace_id}


def audit_dataset_event(
    workspace_id: str, actor_uid: str, action: str, outcome: str,
    *, metadata: dict[str, Any] | None = None,
) -> None:
    provider_mode = os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower()
    with SessionLocal.begin() as db:
        if provider_mode == "supabase":
            context = authorization_context(
                {"uid": actor_uid, "sub": actor_uid, "provider": "supabase"},
                workspace_id,
            )
            if not context.get("workspace_authorized"):
                return
            organization_id = str(context["organization_id"])
            principal_id = str(context["principal_id"])
        else:
            actor = _principal_for_claims(
                db,
                {"uid": actor_uid, "sub": actor_uid, "provider": "firebase"},
                workspace_id,
            )
            if not actor:
                return
            organization_id = str(workspace_id)
            principal_id = str(actor["principal_id"])
        db.execute(text("""INSERT INTO audit_events
            (event_id, organization_id, actor_principal_id, action, outcome, metadata)
            VALUES (:event,:org,:principal,:action,:outcome,CAST(:metadata AS jsonb))"""),
            {"event": _id("evt"), "org": organization_id, "principal": principal_id,
             "action": action, "outcome": outcome, "metadata": json.dumps(metadata or {})})


def _organization_id_for_workspace(db, workspace_id: str) -> str:
    organization_id = db.execute(
        text("""SELECT organization_id
                FROM workspaces
                WHERE workspace_id=:workspace AND status='active'"""),
        {"workspace": workspace_id},
    ).scalar_one_or_none()
    if not organization_id:
        raise AuthzError("Workspace authorization denied.")
    return str(organization_id)


def delete_dataset_authorization(workspace_id: str, dataset_id: str) -> None:
    with SessionLocal.begin() as db:
        organization_id = _organization_id_for_workspace(db, workspace_id)
        db.execute(text("DELETE FROM resource_grants WHERE organization_id=:org AND resource_id=:dataset"),
                   {"org": organization_id, "dataset": dataset_id})
        db.execute(text("DELETE FROM dataset_authorization WHERE organization_id=:org AND dataset_id=:dataset"),
                   {"org": organization_id, "dataset": dataset_id})
        db.execute(text("DELETE FROM authorization_resources WHERE organization_id=:org AND resource_id=:dataset"),
                   {"org": organization_id, "dataset": dataset_id})


def revoke_dataset_working_copies(workspace_id: str, dataset_id: str) -> None:
    """Revoke working-copy authorization records that point at a deleted dataset."""
    with SessionLocal.begin() as db:
        organization_id = _organization_id_for_workspace(db, workspace_id)
        copies = db.execute(
            text("""SELECT working_copy_id
                FROM working_copy_authorization
                WHERE organization_id=:org AND source_dataset_id=:dataset
                  AND status='active'"""),
            {"org": organization_id, "dataset": dataset_id},
        ).scalars().all()
        for copy_id in copies:
            db.execute(
                text("""UPDATE working_copy_authorization
                    SET status='revoked'
                    WHERE organization_id=:org AND working_copy_id=:copy"""),
                {"org": organization_id, "copy": copy_id},
            )
            db.execute(
                text("""DELETE FROM resource_grants
                    WHERE organization_id=:org AND resource_id=:copy"""),
                {"org": organization_id, "copy": copy_id},
            )
            db.execute(
                text("""DELETE FROM authorization_resources
                    WHERE organization_id=:org AND resource_id=:copy
                      AND resource_type='working_copy'"""),
                {"org": organization_id, "copy": copy_id},
            )


def authorize_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str) -> dict[str, Any]:
    if not action.startswith("dataset."):
        raise ValueError("Dataset authorization requires a dataset capability.")
    context = authorization_context(claims, workspace_id)
    if not context["workspace_authorized"]:
        raise AuthzError("Workspace authorization denied.")
    organization_id = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    with SessionLocal() as db:
        resource = db.execute(
            text("""SELECT resource_type, owner_principal_id
                    FROM authorization_resources
                    WHERE organization_id=:org AND resource_id=:dataset"""),
            {"org": organization_id, "dataset": dataset_id},
        ).mappings().first()
        if not resource or resource["resource_type"] != "dataset":
            raise AuthzError("Resource is not accessible.")
        protected = db.execute(
            text("""SELECT protected_original
                    FROM dataset_authorization
                    WHERE organization_id=:org AND dataset_id=:dataset AND status='active'"""),
            {"org": organization_id, "dataset": dataset_id},
        ).scalar_one_or_none()
        grant = db.execute(
            text("""SELECT permissions
                    FROM resource_grants
                    WHERE organization_id=:org AND resource_id=:dataset AND principal_id=:principal"""),
            {"org": organization_id, "dataset": dataset_id,
             "principal": context["principal_id"]},
        ).scalar_one_or_none()
    grant_permissions = list(grant or [])
    logger.info(
        "managed_dataset_authorization dataset=%s action=%s principal=%s organization=%s workspace=%s resource_owner=%s protected=%s grant_present=%s",
        dataset_id,
        action,
        context.get("principal_id"),
        organization_id,
        resolved_workspace_id,
        resource.get("owner_principal_id"),
        protected is not None,
        bool(grant_permissions),
    )
    if protected is None:
        raise AuthzError("Dataset is not accessible.")
    if action not in set(grant_permissions):
        raise AuthzError("Permission denied for this resource.")
    return {**context, "authorized": True, "workspace_id": resolved_workspace_id,
            "organization_id": organization_id, "dataset_id": dataset_id,
            "protected_original": bool(protected)}


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
    organization_id = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    with SessionLocal.begin() as db:
        db.execute(text("""INSERT INTO authorization_resources(organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :copy, 'working_copy', :principal)"""),
                   {"org": organization_id, "copy": copy_id, "principal": context["principal_id"]})
        db.execute(text("""INSERT INTO working_copy_authorization
            (organization_id, working_copy_id, source_dataset_id, source_version, created_by_principal_id)
            VALUES (:org, :copy, :dataset, :version, :principal)"""),
                   {"org": organization_id, "copy": copy_id, "dataset": dataset_id,
                    "version": version, "principal": context["principal_id"]})
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :copy, :principal, CAST(:permissions AS jsonb))"""),
                   {"org": organization_id, "copy": copy_id, "principal": context["principal_id"],
                    "permissions": '["working_copy.view","working_copy.modify","working_copy.delete"]'})
    return {"working_copy_id": copy_id, "organization_id": organization_id, "workspace_id": resolved_workspace_id,
            "source_dataset_id": dataset_id, "source_version": version}


def authorize_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, action: str) -> dict[str, Any]:
    if action not in {"working_copy.view", "working_copy.modify", "working_copy.delete"}:
        raise ValueError("Invalid working copy action.")
    result = authorize(claims, workspace_id, action, working_copy_id)
    organization_id = str(result["organization_id"])
    with SessionLocal() as db:
        row = db.execute(text("""SELECT source_dataset_id, source_version, version
            FROM working_copy_authorization
            WHERE organization_id=:org AND working_copy_id=:copy AND status='active'"""),
                         {"org": organization_id, "copy": working_copy_id}).mappings().first()
    if not row:
        raise AuthzError("Working copy is not accessible.")
    return {**result, "working_copy_id": working_copy_id, "source_dataset_id": row["source_dataset_id"],
            "source_version": row["source_version"], "version": row["version"]}
