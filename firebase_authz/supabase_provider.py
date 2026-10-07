"""Server-side Supabase authorization persistence for organization bootstrap.

 This module accepts already verified provider claims and performs authorization
 against the existing PostgreSQL identity model.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text

from core.db import SessionLocal
from .service import AuthzError
from .schema import ROLE_LEVELS
from . import registration_diagnostics
from .profile_validation import normalize_phone_submission, validate_profile_fields
from .invitation_email import (
    InvitationEmailConfigurationError,
    InvitationEmailDeliveryError,
    send_invitation_email,
)


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
                      role_id: str, expires_at: int | None = None,
                      location_id: str | None = None) -> dict[str, Any]:
    email = str(email or "").strip().lower()
    if "@" not in email or len(email) > 320:
        raise ValueError("Invalid invitation email.")
    location_id = str(location_id or "").strip()
    role_id = {"owner": "organization_owner", "viewer": "external_viewer"}.get(role_id, role_id)
    invitation_roles = {
        "manager", "team_lead", "external_viewer",
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
        if not actor or actor["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        actor_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an Organization Owner or Branch Head can manage invitations.")
        if not location_id:
            # The production Flutter invitation flow predates branch-scoped
            # invitation storage and does not send a client-selected location.
            # Derive the location from the authenticated actor instead of
            # trusting or requiring a client-supplied branch identifier.
            actor_location_rows = db.execute(text("""
                SELECT DISTINCT location_id
                FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND status='active' AND location_id IS NOT NULL
                ORDER BY location_id
            """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all()
            if len(actor_location_rows) == 1:
                location_id = str(actor_location_rows[0]).strip()
            elif len(actor_location_rows) == 0 and "organization_owner" in actor_roles:
                owner_location_rows = db.execute(text("""
                    SELECT location_id
                    FROM locations
                    WHERE organization_id=:org AND status='active'
                    ORDER BY location_id
                """), {"org": workspace_id}).scalars().all()
                if len(owner_location_rows) == 1:
                    location_id = str(owner_location_rows[0]).strip()
            if not location_id:
                raise ValueError("A branch/location is required for an employee invitation. Select an active branch before inviting.")
        location = db.execute(text("""
            SELECT location_id, status FROM locations
            WHERE organization_id=:org AND location_id=:location
        """), {"org": workspace_id, "location": location_id}).mappings().first()
        if not location or location["status"] != "active":
            raise AuthzError("Selected branch/location is not active in this organization.")
        actor_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        if "organization_owner" not in actor_roles:
            scoped = db.execute(text("""
                SELECT 1 FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND location_id=:location AND status='active'
                LIMIT 1
            """), {"org": workspace_id, "principal": actor["principal_id"], "location": location_id}).scalar_one_or_none()
            if scoped is None:
                raise AuthzError("Selected branch/location is outside your management scope.")
        organization_name = db.execute(
            text("SELECT name FROM organizations WHERE organization_id=:org"),
            {"org": workspace_id},
        ).scalar_one_or_none()
        if not organization_name:
            raise AuthzError("Organization could not be resolved for this workspace.")
        organization_name = str(organization_name).strip()
        if role_id == "manager":
            can_invite_manager = db.execute(text("""SELECT 1 FROM member_roles
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id IN ('organization_owner', 'branch_head')
                LIMIT 1"""),
                {"org": workspace_id, "principal": actor["principal_id"]}).scalar_one_or_none()
            if can_invite_manager is None:
                raise AuthzError("Only an Organization Owner or Branch Head can invite a Manager.")

    invitation_id = _id("inv")
    raw_token = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    redirect_base = os.environ.get(
        "INSIGHTFLOW_EMPLOYEE_INVITE_REDIRECT",
        "https://pritishmete.github.io/data_analysis/employee-invite",
    ).strip()
    if not redirect_base:
        raise AuthzError("Employee invitation redirect is not configured.")
    separator = "&" if "?" in redirect_base else "?"
    invitation_url = f"{redirect_base}{separator}token={raw_token}"

    # New invitations are disposable application records. Do not call the
    # Supabase Auth Admin invite API here: that API creates auth.users before
    # the employee has accepted the invitation.
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or actor["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        actor_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an Organization Owner or Branch Head can manage invitations.")

        # A new invitation supersedes older unaccepted invitations for the
        # same organization/email. No Auth account exists to clean up.
        db.execute(text("""UPDATE invitations
            SET status='revoked', revoked_at=now()
            WHERE organization_id=:org
              AND lower(email)=:email
              AND status='invited'"""),
                   {"org": workspace_id, "email": email})

        employee = _allocate_employee_id(db, workspace_id)
        db.execute(text("""INSERT INTO invitations
            (invitation_id, organization_id, email, employee_id, role_id, status,
             expires_at, created_by_principal_id, auth_user_id, location_id,
             email_delivery_status, email_delivery_started_at,
             token_hash, token_created_at)
            VALUES (:id,:org,:email,:employee,:role,'invited',:expires,:creator,NULL,:location,
                    'initiated',now(),:token_hash,now())"""),
                   {"id": invitation_id, "org": workspace_id, "email": email,
                    "employee": employee, "role": role_id, "expires": expiry,
                    "creator": actor["principal_id"], "location": location_id,
                    "token_hash": token_hash})

    try:
        send_invitation_email(
            recipient=email,
            organization_name=organization_name,
            role_id=role_id,
            invitation_url=invitation_url,
            expires_at=expiry,
        )
    except (InvitationEmailConfigurationError, InvitationEmailDeliveryError):
        with SessionLocal.begin() as db:
            db.execute(
                text("""UPDATE invitations
                    SET email_delivery_status='failed'
                    WHERE invitation_id=:id AND status='invited'"""),
                {"id": invitation_id},
            )
        raise

    with SessionLocal.begin() as db:
        db.execute(
            text("""UPDATE invitations
                SET email_delivery_status='sent'
                WHERE invitation_id=:id AND status='invited'"""),
            {"id": invitation_id},
        )

    result = {
        "invitation_id": invitation_id,
        "status": "invited",
        "email_delivery_status": "sent",
        "password_setup_required": True,
        "auth_user_created": False,
    }
    if os.environ.get("INSIGHTFLOW_TESTING", "").strip() == "1":
        result["invitation_token"] = raw_token
    return result

def get_invitation_by_token(token: str) -> dict[str, Any]:
    raw_token = str(token or "").strip()
    if not raw_token or len(raw_token) < 20 or len(raw_token) > 200:
        raise AuthzError("Invitation link is invalid.")
    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    with SessionLocal() as db:
        row = db.execute(text("""SELECT i.invitation_id, i.organization_id,
                o.name AS organization_name, i.email, i.employee_id,
                i.role_id, i.status, i.expires_at
            FROM invitations i
            JOIN organizations o ON o.organization_id=i.organization_id
            WHERE i.token_hash=:token_hash"""), {"token_hash": token_hash}).mappings().first()
    if not row or row["status"] != "invited":
        raise AuthzError("Invitation is no longer active.")
    if row["expires_at"] is not None and row["expires_at"] <= datetime.now(timezone.utc):
        raise AuthzError("Invitation has expired.")
    return dict(row)

def pending_invitations(claims: dict[str, Any]) -> list[dict[str, Any]]:
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT i.invitation_id, i.organization_id, o.name AS organization_name, i.email, i.employee_id,
            i.role_id, i.status, i.expires_at, i.auth_user_id, i.email_delivery_status, i.password_setup_at FROM invitations i
            JOIN organizations o ON o.organization_id=i.organization_id
            WHERE lower(i.email)=:email AND i.status='invited'
              AND i.email_delivery_status IN ('initiated','sent')
              AND (expires_at IS NULL OR expires_at > now())"""), {"email": email}).mappings().all()
    return [dict(row) for row in rows]


def accept_invitation(claims: dict[str, Any], workspace_id: str | None, invitation_id: str, token: str | None = None) -> dict[str, Any]:
    provider, subject = _identity(claims)
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal.begin() as db:
        # The invitation is authoritative for its organization. Only apply a
        # caller-supplied workspace constraint when one was explicitly sent.
        if workspace_id:
            invitation_query = text("""SELECT * FROM invitations
                    WHERE invitation_id=:id
                      AND organization_id=:org
                    FOR UPDATE""")
            invitation_params = {"id": invitation_id, "org": workspace_id}
        else:
            invitation_query = text("""SELECT * FROM invitations
                    WHERE invitation_id=:id
                    FOR UPDATE""")
            invitation_params = {"id": invitation_id}
        invitation = db.execute(
            invitation_query,
            invitation_params,
        ).mappings().first()
        logger.info(
            "invitation_acceptance_lookup invitation_present=%s workspace_constraint=%s",
            invitation is not None,
            bool(workspace_id),
        )
        if not invitation or invitation["status"] != "invited":
            raise AuthzError("Invitation is no longer active.")
        if invitation["expires_at"] is not None and invitation["expires_at"] <= datetime.now(timezone.utc):
            raise AuthzError("Invitation has expired.")
        if invitation["email"].lower() != email:
            raise AuthzError("Invitation identity does not match the authenticated email.")
        invited_auth_user_id = str(invitation.get("auth_user_id") or "").strip()
        if invited_auth_user_id and invited_auth_user_id != uid:
            raise AuthzError("Invitation identity does not match the authenticated account.")
        invitation_token_hash = str(invitation.get("token_hash") or "").strip()
        if invitation_token_hash:
            raw_token = str(token or "").strip()
            if not raw_token:
                if os.environ.get("INSIGHTFLOW_TESTING", "").strip() != "1":
                    raise AuthzError("Invitation token is required.")
            if not secrets.compare_digest(
                invitation_token_hash,
                hashlib.sha256(raw_token.encode("utf-8")).hexdigest(),
            ):
                raise AuthzError("Invitation token is invalid.")
        workspace_id = str(invitation["organization_id"])
        location_id = str(invitation.get("location_id") or "").strip()
        if not location_id and invitation.get("created_by_principal_id"):
            legacy_location = db.execute(text("""
                SELECT min(location_id) AS location_id
                FROM (
                    SELECT DISTINCT location_id FROM organizational_assignments
                    WHERE organization_id=:org AND principal_id=:principal
                      AND status='active' AND location_id IS NOT NULL
                ) scoped_locations
                HAVING count(*) = 1
            """), {"org": workspace_id, "principal": invitation["created_by_principal_id"]}).scalar_one_or_none()
            location_id = str(legacy_location or "").strip()

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
        if location_id:
            db.execute(text("""
                INSERT INTO organizational_assignments
                  (assignment_id, organization_id, principal_id, location_id, role_id, status)
                VALUES (:assignment, :org, :principal, :location, :role, 'active')
                ON CONFLICT DO NOTHING
            """), {"assignment": _id("asg"), "org": workspace_id, "principal": principal_id, "location": location_id, "role": invitation["role_id"]})
        db.execute(text("""UPDATE invitations SET status='accepted', accepted_by_principal_id=:principal,
            accepted_at=now() WHERE invitation_id=:id"""),
                   {"id": invitation_id, "principal": principal_id})
    return {"accepted": True, "organization_id": workspace_id, "employee_id": employee_id, "location_id": location_id or None}


def mark_invitation_password_setup(claims: dict[str, Any], invitation_id: str, token: str | None = None) -> dict[str, Any]:
    email = str(claims.get("email") or "").strip().lower()
    if not bool(claims.get("email_verified")):
        raise AuthzError("Verified email is required.")
    with SessionLocal.begin() as db:
        invitation = db.execute(
            text("""SELECT invitation_id, organization_id, email, status, expires_at, auth_user_id
                    FROM invitations WHERE invitation_id=:id FOR UPDATE"""),
            {"id": invitation_id},
        ).mappings().first()
        if not invitation or invitation["status"] != "invited":
            raise AuthzError("Invitation is no longer active.")
        if invitation["expires_at"] is not None and invitation["expires_at"] <= datetime.now(timezone.utc):
            raise AuthzError("Invitation has expired.")
        if invitation["email"].lower() != email:
            raise AuthzError("Invitation identity does not match the authenticated email.")
        authenticated_uid = str(claims.get("uid") or claims.get("sub") or "").strip()
        invited_auth_user_id = str(invitation.get("auth_user_id") or "").strip()
        if invited_auth_user_id and invited_auth_user_id != authenticated_uid:
            raise AuthzError("Invitation identity does not match the authenticated account.")
        invitation_token_hash = str(invitation.get("token_hash") or "").strip()
        if invitation_token_hash:
            raw_token = str(token or "").strip()
            if not raw_token or not secrets.compare_digest(
                invitation_token_hash,
                hashlib.sha256(raw_token.encode("utf-8")).hexdigest(),
            ):
                raise AuthzError("Invitation token is invalid.")
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
        actor_roles = set(db.execute(text("""SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal"""),
            {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        target_roles = set(db.execute(text("""SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal"""),
            {"org": workspace_id, "principal": target["principal_id"]}).scalars().all())
        if "organization_owner" not in actor_roles:
            actor_level = max((ROLE_LEVELS.get(role, 0) for role in actor_roles), default=0)
            target_level = max((ROLE_LEVELS.get(role, 0) for role in target_roles), default=0)
            if target_level >= actor_level:
                raise AuthzError("You cannot change membership status for an equal or higher role.")
            if "branch_head" in actor_roles:
                same_branch = db.execute(text("""SELECT 1
                    FROM organizational_assignments actor_oa
                    JOIN organizational_assignments target_oa
                      ON target_oa.organization_id=actor_oa.organization_id
                     AND target_oa.location_id=actor_oa.location_id
                    WHERE actor_oa.organization_id=:org
                      AND actor_oa.principal_id=:actor
                      AND actor_oa.role_id='branch_head'
                      AND actor_oa.status='active'
                      AND target_oa.principal_id=:target
                      AND target_oa.status='active'
                    LIMIT 1"""),
                    {"org":workspace_id,"actor":actor["principal_id"],"target":target["principal_id"]}).scalar_one_or_none()
                if not same_branch:
                    raise AuthzError("The target member is outside your branch.")
            elif "manager" in actor_roles or "team_lead" in actor_roles:
                same_branch = db.execute(text("""SELECT 1
                    FROM organizational_assignments actor_oa
                    JOIN organizational_assignments target_oa
                      ON target_oa.organization_id=actor_oa.organization_id
                     AND target_oa.location_id=actor_oa.location_id
                    WHERE actor_oa.organization_id=:org
                      AND actor_oa.principal_id=:actor
                      AND actor_oa.status='active'
                      AND actor_oa.role_id IN ('manager','team_lead')
                      AND target_oa.principal_id=:target
                      AND target_oa.status='active'
                    LIMIT 1"""),
                    {"org":workspace_id,"actor":actor["principal_id"],"target":target["principal_id"]}).scalar_one_or_none()
                if not same_branch:
                    raise AuthzError("The target member is outside your team branch.")
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
    aliases = {"owner": "organization_owner", "viewer": "external_viewer"}
    canonical = aliases.get(role_id, role_id)
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not actor or not target:
            raise AuthzError("Workspace authorization denied.")
        actor_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an Organization Owner or Branch Head can change role assignments.")
        if canonical == "organization_owner" and "organization_owner" not in actor_roles:
            raise AuthzError("Only an Organization Owner can assign the Organization Owner role.")
        if "organization_owner" not in actor_roles:
            same_branch = db.execute(text("""
                SELECT 1
                FROM organizational_assignments actor_oa
                JOIN organizational_assignments target_oa
                  ON target_oa.organization_id=actor_oa.organization_id
                 AND target_oa.location_id=actor_oa.location_id
                WHERE actor_oa.organization_id=:org
                  AND actor_oa.principal_id=:actor
                  AND actor_oa.role_id='branch_head'
                  AND actor_oa.status='active'
                  AND target_oa.principal_id=:target
                  AND target_oa.status='active'
                LIMIT 1
            """), {"org": workspace_id, "actor": actor["principal_id"], "target": target["principal_id"]}).scalar_one_or_none()
            if not same_branch:
                raise AuthzError("The target member is outside your branch.")
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
        if not actor:
            raise AuthzError("Workspace authorization denied.")
        actor_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": actor["principal_id"]}).scalars().all())
        if "organization_owner" not in actor_roles:
            raise AuthzError("Only an Organization Owner can manage RBAC role definitions.")
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
    actor = str(context["principal_id"])
    actor_roles = set(context.get("role_ids", []))
    organization_wide = "organization_owner" in actor_roles
    branch_scoped = bool(actor_roles.intersection({"branch_head", "manager"}))
    team_scoped = "team_lead" in actor_roles

    with SessionLocal() as db:
        if organization_wide:
            member_scope = "TRUE"
            member_params = {"org": org, "actor": actor}
        elif branch_scoped:
            member_scope = """EXISTS (
                SELECT 1 FROM organizational_assignments scope_oa
                WHERE scope_oa.organization_id=m.organization_id
                  AND scope_oa.principal_id=:actor
                  AND scope_oa.status='active'
                  AND scope_oa.location_id=oa.location_id
            )"""
            member_params = {"org": org, "actor": actor}
        elif team_scoped:
            member_scope = """EXISTS (
                SELECT 1 FROM organizational_assignments scope_oa
                WHERE scope_oa.organization_id=m.organization_id
                  AND scope_oa.principal_id=:actor
                  AND scope_oa.role_id='team_lead'
                  AND scope_oa.status='active'
                  AND scope_oa.location_id=oa.location_id
                  AND scope_oa.section_id=oa.section_id
            )"""
            member_params = {"org": org, "actor": actor}
        else:
            member_scope = "m.principal_id=:actor"
            member_params = {"org": org, "actor": actor}

        members = db.execute(text(f"""SELECT b.firebase_uid AS uid, m.employee_id, m.status,
            COALESCE(array_agg(DISTINCT mr.role_id) FILTER (WHERE mr.role_id IS NOT NULL), ARRAY[]::text[]) AS role_ids
            FROM organization_members m
            JOIN identity_bindings b ON b.principal_id=m.principal_id
            LEFT JOIN member_roles mr
              ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
            LEFT JOIN organizational_assignments oa
              ON oa.organization_id=m.organization_id AND oa.principal_id=m.principal_id AND oa.status='active'
            WHERE m.organization_id=:org AND {member_scope}
            GROUP BY b.firebase_uid,m.employee_id,m.status"""), member_params).mappings().all()

        if organization_wide:
            dataset_scope = "TRUE"
        elif "branch_head" in actor_roles:
            dataset_scope = """da.location_id IN (
                SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:actor
                  AND role_id='branch_head' AND status='active'
                  AND location_id IS NOT NULL
            )"""
        else:
            # Managers, Team Leads and lower roles use the explicit copy-request
            # workflow. The original/master registry is not exposed by this
            # legacy management snapshot.
            dataset_scope = "FALSE"
        datasets = db.execute(text(f"""SELECT da.dataset_id, da.protected_original,
            da.status AS authorization_status, r.owner_principal_id,
            ds.dataset_name, ds.original_filename, ds.row_count, ds.column_count,
            ds.current_version_id AS current_version, ds.version_number,
            ds.file_size, ds.uploaded_by, ds.created_at, ds.status AS dataset_status
            FROM dataset_authorization da
            JOIN authorization_resources r
              ON r.organization_id=da.organization_id AND r.resource_id=da.dataset_id
            LEFT JOIN datasets ds
              ON ds.organization_id=da.organization_id AND ds.dataset_id=da.dataset_id
            WHERE da.organization_id=:org AND da.status='active' AND {dataset_scope}"""),
            {"org": org, "actor": actor}).mappings().all()

        if organization_wide:
            working_copy_scope = "TRUE"
        elif "branch_head" in actor_roles:
            working_copy_scope = """EXISTS (
                SELECT 1 FROM dataset_authorization da
                WHERE da.organization_id=wc.organization_id
                  AND da.dataset_id=wc.source_dataset_id
                  AND da.location_id IN (
                    SELECT location_id FROM organizational_assignments
                    WHERE organization_id=:org AND principal_id=:actor
                      AND role_id='branch_head' AND status='active'
                      AND location_id IS NOT NULL
                  )
            )"""
        else:
            working_copy_scope = """EXISTS (
                SELECT 1 FROM working_copy_assignments wca
                WHERE wca.organization_id=wc.organization_id
                  AND wca.working_copy_id=wc.working_copy_id
                  AND wca.principal_id=:actor
                  AND wca.status='active'
            )"""
        working_copies = db.execute(text(f"""SELECT wc.working_copy_id, wc.source_dataset_id,
            wc.source_version, wc.version, wc.status, wc.created_by_principal_id
            FROM working_copy_authorization wc
            WHERE wc.organization_id=:org AND wc.status='active' AND {working_copy_scope}"""),
            {"org": org, "actor": actor}).mappings().all()

        if organization_wide:
            approved_scope = "TRUE"
        elif "branch_head" in actor_roles:
            approved_scope = """a.principal_id IN (
                SELECT oa.principal_id FROM organizational_assignments oa
                WHERE oa.organization_id=:org AND oa.location_id IN (
                    SELECT location_id FROM organizational_assignments
                    WHERE organization_id=:org AND principal_id=:actor
                      AND role_id='branch_head' AND status='active'
                ) AND oa.status='active'
            )"""
        else:
            approved_scope = "a.principal_id=:actor"
        approved = db.execute(text(f"""SELECT b.firebase_uid AS uid, a.employee_id, a.status
            FROM approved_employees a JOIN identity_bindings b ON b.principal_id=a.principal_id
            WHERE a.organization_id=:org AND a.status='active' AND {approved_scope}"""),
            {"org": org, "actor": actor}).mappings().all()

        if organization_wide or "branch_head" in actor_roles:
            delegation_scope = "TRUE"
        elif team_scoped:
            delegation_scope = "team_lead_principal_id=:actor"
        else:
            delegation_scope = "FALSE"
        delegations = db.execute(text(f"""SELECT delegation_id, team_lead_principal_id,
            member_principal_ids, dataset_ids, permissions, expires_at, status
            FROM delegations WHERE organization_id=:org AND {delegation_scope}"""),
            {"org": org, "actor": actor}).mappings().all()

        audit = []
        if organization_wide:
            audit = db.execute(text("""SELECT event_id, actor_principal_id, action, outcome,
                metadata, created_at FROM audit_events WHERE organization_id=:org
                ORDER BY created_at DESC LIMIT 100"""), {"org": org}).mappings().all()
        elif "branch_head" in actor_roles and "audit.view" in set(context.get("permissions", [])):
            audit = db.execute(text("""SELECT event_id, actor_principal_id, action, outcome,
                metadata, created_at FROM audit_events
                WHERE organization_id=:org
                  AND (metadata->>'location_id') = ANY(
                    SELECT location_id::text
                    FROM organizational_assignments
                    WHERE organization_id=:org AND principal_id=:actor
                      AND role_id='branch_head' AND status='active'
                      AND location_id IS NOT NULL
                  )
                ORDER BY created_at DESC LIMIT 100"""),
                {"org": org, "actor": actor}).mappings().all()

        actor_email = str(claims.get("email") or "").strip().lower()
        invitation_query = """
            SELECT
                i.invitation_id,
                i.email,
                i.employee_id,
                i.role_id,
                i.status,
                i.expires_at,
                i.location_id,
                l.name AS location_name,
                i.created_by_principal_id,
                creator_profile.full_name AS sender_name,
                COALESCE(
                    (
                        SELECT oa.role_id
                        FROM organizational_assignments oa
                        WHERE oa.organization_id = i.organization_id
                          AND oa.principal_id = i.created_by_principal_id
                          AND oa.location_id = i.location_id
                          AND oa.status = 'active'
                        ORDER BY oa.assignment_id
                        LIMIT 1
                    ),
                    (
                        SELECT mr.role_id
                        FROM member_roles mr
                        WHERE mr.organization_id = i.organization_id
                          AND mr.principal_id = i.created_by_principal_id
                        ORDER BY mr.role_id
                        LIMIT 1
                    )
                ) AS sender_role_id,
                recipient_profile.full_name AS recipient_name,
                COALESCE(
                    (
                        SELECT oa.role_id
                        FROM organizational_assignments oa
                        WHERE oa.organization_id = i.organization_id
                          AND oa.principal_id = i.accepted_by_principal_id
                          AND oa.status = 'active'
                        ORDER BY oa.assignment_id
                        LIMIT 1
                    ),
                    i.role_id
                ) AS recipient_role_id,
                i.accepted_by_principal_id
            FROM invitations i
            LEFT JOIN locations l
              ON l.organization_id = i.organization_id
             AND l.location_id = i.location_id
            LEFT JOIN organization_member_profiles creator_profile
              ON creator_profile.organization_id = i.organization_id
             AND creator_profile.principal_id = i.created_by_principal_id
            LEFT JOIN organization_member_profiles recipient_profile
              ON recipient_profile.organization_id = i.organization_id
             AND recipient_profile.principal_id = i.accepted_by_principal_id
            WHERE i.organization_id = :org
              AND (
                    'organization_owner' = ANY(:actor_roles)
                    OR lower(i.email) = :actor_email
                    OR (
                        'branch_head' = ANY(:actor_roles)
                        AND EXISTS (
                            SELECT 1
                            FROM organizational_assignments actor_assignment
                            WHERE actor_assignment.organization_id = i.organization_id
                              AND actor_assignment.principal_id = :actor_principal
                              AND actor_assignment.location_id = i.location_id
                              AND actor_assignment.status = 'active'
                        )
                    )
              )
            ORDER BY i.created_at DESC NULLS LAST, i.invitation_id
        """
        invitations = db.execute(
            text(invitation_query),
            {
                "org": org,
                "actor_roles": list(actor_roles),
                "actor_email": actor_email,
                "actor_principal": actor,
            },
        ).mappings().all()
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
            "invitations": [
                {
                    **dict(row),
                    "sender_name": row["sender_name"] or "Unknown sender",
                    "sender_role_id": row["sender_role_id"],
                    "recipient_name": row["recipient_name"],
                    "recipient_display": row["recipient_name"] or row["email"],
                }
                for row in invitations
            ],
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
                "profile_complete": profile_complete
                if row["organization_id"] == selected["organization_id"]
                else False,
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
    if "dataset.manage_acl" not in context["permissions"] and "dataset.upload" not in context["permissions"]:
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
        owner_location = db.execute(text("""SELECT location_id FROM organizational_assignments
            WHERE organization_id=:org AND principal_id=:owner
              AND role_id IN ('branch_head','manager') AND status='active' AND location_id IS NOT NULL
            ORDER BY CASE WHEN role_id='branch_head' THEN 0 ELSE 1 END, assignment_id LIMIT 1"""),
            {"org": organization_id, "owner": owner}).scalar_one_or_none()
        db.execute(text("""INSERT INTO dataset_authorization
            (organization_id, dataset_id, owner_principal_id, protected_original, location_id)
            VALUES (:org, :dataset, :owner, :protected, :location)
            ON CONFLICT (organization_id, dataset_id)
            DO UPDATE SET owner_principal_id=EXCLUDED.owner_principal_id,
                          protected_original=EXCLUDED.protected_original,
                          location_id=COALESCE(EXCLUDED.location_id, dataset_authorization.location_id),
                          status='active'"""),
            {"org": organization_id, "dataset": dataset_id, "owner": owner,
             "protected": protected, "location": owner_location})
        db.execute(text("""INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :dataset, :owner, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions"""),
                   {"org": organization_id, "dataset": dataset_id, "owner": owner,
                    "permissions": '["dataset.view_original","dataset.create_working_copy","dataset.manage_acl"]'})
    return {"dataset_id": dataset_id, "organization_id": organization_id, "workspace_id": resolved_workspace_id}



def request_dataset_copy(claims: dict[str, Any], workspace_id: str, dataset_id: str, note: str | None = None) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"manager", "team_lead"}):
        raise AuthzError("Only Managers and Team Leads can request a dataset copy.")
    org = str(context["organization_id"])
    with SessionLocal.begin() as db:
        dataset = db.execute(text("""SELECT da.location_id FROM dataset_authorization da
            WHERE da.organization_id=:org AND da.dataset_id=:dataset AND da.status='active'"""),
            {"org": org, "dataset": dataset_id}).mappings().first()
        if not dataset:
            raise AuthzError("Dataset is not available for copy authorization.")
        location = db.execute(text("""SELECT location_id FROM organizational_assignments
            WHERE organization_id=:org AND principal_id=:principal
              AND role_id IN ('manager','team_lead') AND status='active'
            ORDER BY CASE WHEN location_id = :dataset_location THEN 0 ELSE 1 END
            LIMIT 1"""), {"org": org, "principal": context["principal_id"], "dataset_location": dataset["location_id"]}).scalar_one_or_none()
        if dataset["location_id"] and location != dataset["location_id"]:
            raise AuthzError("The dataset belongs to a different branch.")
        existing = db.execute(text("""SELECT request_id FROM authorization_requests
            WHERE organization_id=:org AND dataset_id=:dataset
              AND requester_principal_id=:principal AND status='pending'"""),
            {"org": org, "dataset": dataset_id, "principal": context["principal_id"]}).scalar_one_or_none()
        if existing:
            return {"request_id": existing, "status": "pending"}
        rid = _id("req")
        db.execute(text("""INSERT INTO authorization_requests
            (request_id, organization_id, workspace_id, requester_principal_id, dataset_id, location_id, note)
            VALUES (:id,:org,:workspace,:requester,:dataset,:location,:note)"""),
            {"id": rid, "org": org, "workspace": context["workspace_id"], "requester": context["principal_id"],
             "dataset": dataset_id, "location": dataset["location_id"], "note": str(note or "")[:1000]})
        return {"request_id": rid, "status": "pending", "dataset_id": dataset_id}


def list_copy_requests(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    context = authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner","branch_head","manager","team_lead"}):
        raise AuthzError("Authorization requests are not available to this role.")
    org = str(context["organization_id"])
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT r.request_id, r.dataset_id, r.status, r.note, r.created_at,
                r.reviewed_at, r.resulting_working_copy_id, r.location_id,
                requester.employee_id, profile.full_name AS requester_name
            FROM authorization_requests r
            JOIN organization_members requester ON requester.organization_id=r.organization_id
              AND requester.principal_id=r.requester_principal_id
            LEFT JOIN organization_member_profiles profile ON profile.organization_id=r.organization_id
              AND profile.principal_id=r.requester_principal_id
            WHERE r.organization_id=:org
              AND (:orgwide OR r.location_id = ANY(:locations))
            ORDER BY r.created_at DESC"""),
            {"org": org, "orgwide": "organization_owner" in roles,
             "locations": list(db.execute(text("""SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal AND status='active' AND location_id IS NOT NULL"""),
                {"org": org,"principal":context["principal_id"]}).scalars().all())}).mappings().all()
        return [dict(row) for row in rows]


def approve_copy_request(claims: dict[str, Any], workspace_id: str, request_id: str, approve: bool) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner","branch_head"}):
        raise AuthzError("Only a Branch Head or Organization Owner can approve copy requests.")
    org = str(context["organization_id"])
    with SessionLocal.begin() as db:
        req = db.execute(text("""SELECT * FROM authorization_requests
            WHERE organization_id=:org AND request_id=:request AND status='pending' FOR UPDATE"""),
            {"org": org, "request": request_id}).mappings().first()
        if not req:
            raise AuthzError("Pending authorization request not found.")
        if "organization_owner" not in roles:
            branch = db.execute(text("""SELECT 1 FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='branch_head' AND location_id=:location AND status='active'"""),
                {"org": org,"principal":context["principal_id"],"location":req["location_id"]}).scalar_one_or_none()
            if not branch:
                raise AuthzError("This request belongs to another branch.")
        if not approve:
            db.execute(text("""UPDATE authorization_requests SET status='rejected', reviewed_by_principal_id=:reviewer, reviewed_at=now(), updated_at=now()
                WHERE request_id=:request"""), {"requester":request_id,"reviewer":context["principal_id"],"request":request_id})
            return {"request_id": request_id, "status": "rejected"}
    copy = create_working_copy(claims, workspace_id, req["dataset_id"], None, None)
    with SessionLocal.begin() as db:
        db.execute(text("""INSERT INTO working_copy_assignments
            (working_copy_id, organization_id, principal_id, assigned_by_principal_id)
            VALUES (:copy,:org,:principal,:assigner)"""),
            {"copy":copy["working_copy_id"],"org":org,"principal":req["requester_principal_id"],"assigner":context["principal_id"]})
        db.execute(text("""UPDATE authorization_requests
            SET status='approved', reviewed_by_principal_id=:reviewer, reviewed_at=now(),
                resulting_working_copy_id=:copy, updated_at=now()
            WHERE request_id=:request"""),
            {"reviewer":context["principal_id"],"copy":copy["working_copy_id"],"request":request_id})
    return {"request_id": request_id, "status": "approved", "working_copy": copy}


def assign_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, target_uid: str) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner","branch_head"}):
        raise AuthzError("Only a Branch Head or Organization Owner can assign working copies.")
    authorize_working_copy(claims, workspace_id, working_copy_id, "working_copy.assign")
    org = str(context["organization_id"])
    with SessionLocal.begin() as db:
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not target:
            raise AuthzError("Assignment target is not an active member.")
        source = db.execute(text("""SELECT da.location_id FROM working_copy_authorization wc
            JOIN dataset_authorization da ON da.organization_id=wc.organization_id AND da.dataset_id=wc.source_dataset_id
            WHERE wc.organization_id=:org AND wc.working_copy_id=:copy"""),
            {"org":org,"copy":working_copy_id}).mappings().first()
        if not source:
            raise AuthzError("Working copy is not accessible.")
        if roles.intersection({"manager","team_lead"}):
            scoped = db.execute(text("""SELECT 1 FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:actor AND location_id=:location
                  AND status='active' AND role_id IN ('manager','team_lead') LIMIT 1"""),
                {"org":org,"actor":context["principal_id"],"location":source["location_id"]}).scalar_one_or_none()
            if not scoped:
                raise AuthzError("The working copy is outside your branch scope.")
        db.execute(text("""UPDATE working_copy_assignments SET status='revoked', updated_at=now()
            WHERE organization_id=:org AND working_copy_id=:copy AND status='active'"""),
            {"org":org,"copy":working_copy_id})
        db.execute(text("""INSERT INTO working_copy_assignments
            (working_copy_id, organization_id, principal_id, assigned_by_principal_id)
            VALUES (:copy,:org,:principal,:assigner)
            ON CONFLICT (organization_id, working_copy_id, principal_id)
            DO UPDATE SET assigned_by_principal_id=EXCLUDED.assigned_by_principal_id, status='active', updated_at=now()"""),
            {"copy":working_copy_id,"org":org,"principal":target["principal_id"],"assigner":context["principal_id"]})
    return {"working_copy_id": working_copy_id, "assigned_to_principal_id": target["principal_id"], "status": "active"}



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
        resource = db.execute(text("""SELECT resource_type, owner_principal_id
                FROM authorization_resources
                WHERE organization_id=:org AND resource_id=:dataset"""),
            {"org": organization_id, "dataset": dataset_id}).mappings().first()
        row = db.execute(text("""SELECT protected_original, location_id
                FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:dataset AND status='active'"""),
            {"org": organization_id, "dataset": dataset_id}).mappings().first()
        grant = db.execute(text("""SELECT permissions FROM resource_grants
                WHERE organization_id=:org AND resource_id=:dataset AND principal_id=:principal"""),
            {"org": organization_id, "dataset": dataset_id, "principal": context["principal_id"]}).scalar_one_or_none()
        actor_roles = set(db.execute(text("""SELECT role_id FROM member_roles
                WHERE organization_id=:org AND principal_id=:principal"""),
            {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
        branch_locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='branch_head' AND status='active' AND location_id IS NOT NULL"""),
            {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
    if not resource or resource["resource_type"] != "dataset" or not row:
        raise AuthzError("Dataset is not accessible.")
    grant_permissions = set(grant or [])
    # Original/master operations are role-scoped. Managers may upload into
    # their own branch, while Branch Heads may manage the branch's originals.
    if action == "dataset.upload":
        if "organization_owner" in actor_roles:
            pass
        elif "branch_head" in actor_roles:
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in branch_locations}:
                raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
        elif "manager" in actor_roles:
            manager_locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
                    WHERE organization_id=:org AND principal_id=:principal
                      AND role_id='manager' AND status='active' AND location_id IS NOT NULL"""),
                {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in manager_locations}:
                raise AuthzError("The dataset belongs to a branch outside your Manager scope.")
        else:
            raise AuthzError("Only a Manager, Branch Head, or Organization Owner can upload datasets.")
    elif action == "dataset.view_original":
        if "organization_owner" in actor_roles:
            pass
        elif "branch_head" in actor_roles:
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in branch_locations}:
                raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
        elif "manager" in actor_roles:
            manager_locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='manager' AND status='active' AND location_id IS NOT NULL"""),
                {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in manager_locations}:
                raise AuthzError("The dataset belongs to a branch outside your Manager scope.")
        else:
            raise AuthzError("Only a Manager, Branch Head, or Organization Owner can view an original dataset.")
    elif action in {"dataset.delete", "dataset.share", "dataset.manage_acl"}:
        if "organization_owner" not in actor_roles and "branch_head" not in actor_roles:
            raise AuthzError("Only a Branch Head or Organization Owner can manage the original dataset.")
        if "organization_owner" not in actor_roles and (not row["location_id"] or str(row["location_id"]) not in {str(v) for v in branch_locations}):
            raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
    elif action == "dataset.create_working_copy":
        # Branch Heads and Managers can copy datasets inside their branch scope.
        # All lower roles require an explicit per-dataset working-copy grant.
        if "organization_owner" not in actor_roles and "branch_head" not in actor_roles and "manager" not in actor_roles:
            if "dataset.create_working_copy" not in grant_permissions:
                raise AuthzError("This dataset has not been authorized for copying by this user.")
        if "manager" in actor_roles and "branch_head" not in actor_roles and "organization_owner" not in actor_roles:
            manager_locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='manager' AND status='active' AND location_id IS NOT NULL"""),
                {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in manager_locations}:
                raise AuthzError("The dataset belongs to a branch outside your Manager scope.")
    elif action not in grant_permissions:
        raise AuthzError("Permission denied for this resource.")
    return {**context, "authorized": True, "workspace_id": resolved_workspace_id,
            "organization_id": organization_id, "dataset_id": dataset_id,
            "protected_original": bool(row["protected_original"]), "location_id": row["location_id"]}
    return {**context, "authorized": True, "workspace_id": resolved_workspace_id,
            "organization_id": organization_id, "dataset_id": dataset_id,
            "protected_original": bool(row["protected_original"]), "location_id": row["location_id"]}



def set_dataset_grant(claims: dict[str, Any], workspace_id: str, dataset_id: str,
                      target_uid: str, permissions: list[str]) -> bool:
    # Original/master access is never delegated. A Branch Head explicitly
    # grants only the ability to create a working copy of this dataset.
    allowed = {"dataset.create_working_copy"}
    if any(p not in allowed for p in permissions):
        raise ValueError("Only dataset.create_working_copy can be delegated.")
    context = authorization_context(claims, workspace_id)
    if "organization_owner" not in set(context.get("role_ids", [])) and "branch_head" not in set(context.get("role_ids", [])):
        raise AuthzError("Only a Branch Head or Organization Owner can authorize dataset copies.")
    organization_id = str(context["organization_id"])
    with SessionLocal() as db:
        row = db.execute(text("""SELECT location_id FROM dataset_authorization
            WHERE organization_id=:org AND dataset_id=:dataset AND status='active'"""),
            {"org": organization_id, "dataset": dataset_id}).mappings().first()
        if not row:
            raise AuthzError("Dataset is not accessible.")
        if "organization_owner" not in set(context.get("role_ids", [])):
            locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND role_id='branch_head' AND status='active' AND location_id IS NOT NULL"""),
                {"org": organization_id, "principal": context["principal_id"]}).scalars().all())
            if not row["location_id"] or str(row["location_id"]) not in {str(v) for v in locations}:
                raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
    return set_resource_grant(
        claims, workspace_id, dataset_id, target_uid, permissions,
        required_permission="dataset.manage_acl",
    )
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
             "permissions": '["working_copy.view","working_copy.modify","working_copy.delete","working_copy.assign"]'})
    return {"working_copy_id": copy_id, "organization_id": organization_id, "workspace_id": resolved_workspace_id,
            "source_dataset_id": dataset_id, "source_version": version}



def authorize_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, action: str) -> dict[str, Any]:
    if action not in {"working_copy.view", "working_copy.modify", "working_copy.delete", "working_copy.assign"}:
        raise ValueError("Invalid working copy action.")
    context = authorization_context(claims, workspace_id)
    if not context["workspace_authorized"]:
        raise AuthzError("Workspace authorization denied.")
    organization_id = str(context["organization_id"])
    with SessionLocal() as db:
        row = db.execute(text("""SELECT source_dataset_id, source_version, version, created_by_principal_id
            FROM working_copy_authorization
            WHERE organization_id=:org AND working_copy_id=:copy AND status='active'"""),
            {"org": organization_id, "copy": working_copy_id}).mappings().first()
        if not row:
            raise AuthzError("Working copy is not accessible.")
        assignment = db.execute(text("""SELECT 1 FROM working_copy_assignments
            WHERE organization_id=:org AND working_copy_id=:copy
              AND principal_id=:principal AND status='active'"""),
            {"org": organization_id, "copy": working_copy_id, "principal": context["principal_id"]}).scalar_one_or_none()
        grant = db.execute(text("""SELECT permissions FROM resource_grants
            WHERE organization_id=:org AND resource_id=:copy AND principal_id=:principal"""),
            {"org": organization_id, "copy": working_copy_id, "principal": context["principal_id"]}).scalar_one_or_none()
    allowed = set(grant or [])
    if action == "working_copy.assign":
        if not set(context.get("role_ids", [])).intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only a Branch Head or Organization Owner can assign working copies.")
        if "working_copy.assign" not in set(context.get("permissions", [])):
            raise AuthzError("You don't have permission to assign this working copy.")
    if not assignment and action != "working_copy.assign" and action not in allowed:
        raise AuthzError("This working copy is assigned to another user.")
    if action == "working_copy.assign" and not assignment and "organization_owner" not in set(context.get("role_ids", [])) and "branch_head" not in set(context.get("role_ids", [])):
        raise AuthzError("A working copy must be assigned to its current manager before it can be reassigned.")
    return {**context, "authorized": True, "organization_id": organization_id,
            "working_copy_id": working_copy_id, "source_dataset_id": row["source_dataset_id"],
            "source_version": row["source_version"], "version": row["version"]}




def list_dataset_catalog(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    context = authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner","branch_head","manager","team_lead"}):
        return []
    org = str(context["organization_id"])
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT da.dataset_id, ds.dataset_name, ds.original_filename,
                da.location_id, l.name AS location_name
            FROM dataset_authorization da
            LEFT JOIN datasets ds ON ds.organization_id=da.organization_id AND ds.dataset_id=da.dataset_id
            LEFT JOIN locations l ON l.organization_id=da.organization_id AND l.location_id=da.location_id
            WHERE da.organization_id=:org AND da.status='active'
            ORDER BY lower(coalesce(ds.dataset_name, da.dataset_id)), da.dataset_id"""),
            {"org": org}).mappings().all()
        if "organization_owner" in roles:
            return [dict(row) for row in rows]
        locations = set(db.execute(text("""SELECT location_id FROM organizational_assignments
            WHERE organization_id=:org AND principal_id=:principal AND status='active' AND location_id IS NOT NULL"""),
            {"org":org,"principal":context["principal_id"]}).scalars().all())
        return [dict(row) for row in rows if row["location_id"] is None or row["location_id"] in locations]



