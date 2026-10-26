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
from .schema import ROLE_LEVELS
from . import registration_diagnostics
from .profile_validation import normalize_phone_submission, validate_profile_fields
from .supabase_admin import (
    SupabaseAdminConfigurationError,
    SupabaseAdminOperationError,
    find_user_by_email,
    invite_user_by_email,
    is_existing_auth_user_error,
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
                  AND role_id='branch_head'
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
        is_owner = "organization_owner" in actor_roles
        if not is_owner:
            # A stale member_roles row is not sufficient to retain invitation
            # privileges. Require the authoritative active Branch Head grant
            # for the exact target branch.
            scoped = db.execute(text("""
                SELECT 1 FROM organizational_assignments
                WHERE organization_id=:org AND principal_id=:principal
                  AND location_id=:location AND role_id='branch_head'
                  AND status='active'
                LIMIT 1
            """), {"org": workspace_id, "principal": actor["principal_id"], "location": location_id}).scalar_one_or_none()
            if scoped is None:
                raise AuthzError("Only an active Branch Head assigned to this branch can manage its invitations.")
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
    redirect_to = os.environ.get("INSIGHTFLOW_EMPLOYEE_INVITE_REDIRECT", "https://pritishmete.github.io/data_analysis/employee-invite").strip()
    if not redirect_to:
        raise AuthzError("Employee invitation redirect is not configured.")

    auth_user_id = ""
    delivery_status = "initiated"
    password_setup_required = True
    try:
        invited = invite_user_by_email(email, redirect_to, organization_name=organization_name)
        auth_user_id = invited["user_id"]
        if not auth_user_id:
            raise SupabaseAdminOperationError("Supabase Auth did not return an invited user ID.")
    except Exception as invite_error:
        if not is_existing_auth_user_error(invite_error):
            raise
        try:
            existing = find_user_by_email(email)
        except (SupabaseAdminConfigurationError, SupabaseAdminOperationError):
            # Keep trusted Admin failures distinct from application authorization
            # failures. The route converts these to a safe 503 response.
            raise
        except Exception as lookup_error:
            raise SupabaseAdminOperationError(
                "Supabase Auth existing-user lookup failed."
            ) from lookup_error
        if not existing or existing.get("user_id") is None:
            raise SupabaseAdminOperationError(
                "Supabase Auth reported an existing user, but the trusted lookup "
                "did not return that exact email."
            ) from invite_error
        if not existing.get("email_confirmed"):
            raise AuthzError(
                "This email already has an unconfirmed Auth account. "
                "Complete its existing confirmation flow before accepting an employee invitation."
            ) from invite_error
        auth_user_id = str(existing["user_id"]).strip()
        delivery_status = "existing_account"
        password_setup_required = False

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
        db.execute(text("""INSERT INTO invitations
            (invitation_id, organization_id, email, role_id, status,
             expires_at, created_by_principal_id, auth_user_id, location_id,
             email_delivery_status, email_delivery_started_at)
            VALUES (:id,:org,:email,:role,'invited',:expires,:creator,:auth_user,:location,
                    :delivery_status, CASE WHEN :delivery_status='initiated' THEN now() ELSE NULL END)"""),
                   {"id": invitation_id, "org": workspace_id, "email": email,
                    "role": role_id, "expires": expiry, "creator": actor["principal_id"],
                    "auth_user": auth_user_id, "location": location_id, "delivery_status": delivery_status})
    return {"invitation_id": invitation_id, "status": "invited",
            "email_delivery_status": delivery_status,
            "password_setup_required": password_setup_required}

def pending_invitations(claims: dict[str, Any]) -> list[dict[str, Any]]:
    email = str(claims.get("email") or "").strip().lower()
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT i.invitation_id, i.organization_id, o.name AS organization_name, i.email, i.employee_id,
            i.role_id, i.status, i.expires_at, i.auth_user_id, i.email_delivery_status, i.password_setup_at FROM invitations i
            JOIN organizations o ON o.organization_id=i.organization_id
            WHERE lower(i.email)=:email AND i.status='invited'
              AND (expires_at IS NULL OR expires_at > now())"""), {"email": email}).mappings().all()
    return [dict(row) for row in rows]


def accept_invitation(claims: dict[str, Any], workspace_id: str | None, invitation_id: str) -> dict[str, Any]:
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
            text("""SELECT employee_id, status FROM organization_members
                    WHERE organization_id=:org AND principal_id=:principal
                    FOR UPDATE"""),
            {"org": workspace_id, "principal": principal_id},
        ).mappings().first()
        if existing_member and str(existing_member.get("status") or "").strip().lower() in {
            "suspended", "removed", "revoked", "inactive", "disabled",
        }:
            raise AuthzError("This membership is suspended or removed and cannot be reactivated by an invitation.")
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

def _active_assigned_role_rows(db, workspace_id: str, principal_id: str) -> list[dict[str, Any]]:
    """Return role assignments backed by active membership and active scope."""
    rows = db.execute(text("""
        SELECT oa.assignment_id, oa.location_id, oa.section_id, oa.role_id
        FROM organizational_assignments oa
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        JOIN member_roles mr
          ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
         AND mr.role_id=oa.role_id
        LEFT JOIN locations l
          ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
        LEFT JOIN sections s
          ON s.organization_id=oa.organization_id AND s.section_id=oa.section_id
         AND s.location_id=oa.location_id
        WHERE oa.organization_id=:org AND m.workspace_id=:workspace
          AND oa.principal_id=:principal AND m.status='active' AND oa.status='active'
          AND (
            oa.role_id='organization_owner'
            OR (
              oa.location_id IS NOT NULL AND l.status='active'
              AND (oa.section_id IS NULL OR s.status='active')
              AND (oa.role_id <> 'team_lead' OR oa.section_id IS NOT NULL)
            )
          )
        ORDER BY oa.role_id, oa.location_id, oa.section_id, oa.assignment_id
    """), {"org": workspace_id, "workspace": workspace_id,
           "principal": principal_id}).mappings().all()
    return [dict(row) for row in rows]

def set_membership_status(claims: dict[str, Any], workspace_id: str, target_uid: str, status: str) -> bool:
    if status not in {"approved", "active", "suspended", "removed"}:
        raise ValueError("Invalid membership status.")
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        target = _principal_for_uid(db, target_uid, workspace_id)
        if not actor or actor["status"] != "active" or not target:
            raise AuthzError("Workspace authorization denied.")

        actor_assignments = _active_assigned_role_rows(db, workspace_id, str(actor["principal_id"]))
        actor_roles = {str(row["role_id"]) for row in actor_assignments}
        # A Manager's historical membership.manage bit is not authority to
        # suspend, remove, or reactivate people.
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an active Organization Owner or Branch Head can change membership status.")

        target_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": target["principal_id"]}).scalars().all())
        if status in {"suspended", "removed"}:
            _guard_last_owner(db, workspace_id, target["principal_id"])

        if "organization_owner" not in actor_roles:
            actor_level = max((ROLE_LEVELS.get(role, 0) for role in actor_roles), default=0)
            target_level = max((ROLE_LEVELS.get(role, 0) for role in target_roles), default=0)
            if target_level >= actor_level:
                raise AuthzError("You cannot change membership status for an equal or higher role.")
            branch_ids = {
                str(row["location_id"]) for row in actor_assignments
                if row["role_id"] == "branch_head" and row["location_id"] is not None
            }
            if len(branch_ids) != 1:
                raise AuthzError("An unambiguous active Branch Head branch assignment is required.")
            branch_id = next(iter(branch_ids))
            target_scope = db.execute(text("""
                SELECT 1
                FROM organizational_assignments target_oa
                JOIN organization_members target_member
                  ON target_member.organization_id=target_oa.organization_id
                 AND target_member.principal_id=target_oa.principal_id
                JOIN locations l
                  ON l.organization_id=target_oa.organization_id
                 AND l.location_id=target_oa.location_id
                WHERE target_oa.organization_id=:org AND target_member.workspace_id=:workspace
                  AND target_oa.principal_id=:target AND target_oa.location_id=:location
                  AND target_oa.status='active' AND l.status='active'
                LIMIT 1
            """), {"org": workspace_id, "workspace": workspace_id,
                    "target": target["principal_id"], "location": branch_id}).scalar_one_or_none()
            if target_scope is None:
                raise AuthzError("The target member is outside your branch.")

        db.execute(text("""
            UPDATE organization_members SET status=:status
            WHERE organization_id=:org AND principal_id=:principal
        """), {"status": status, "org": workspace_id, "principal": target["principal_id"]})
    return True

def _principal_for_uid(db, uid: str, organization_id: str):
    return db.execute(text("""SELECT b.principal_id, m.employee_id, m.status
        FROM identity_bindings b
        JOIN organization_members m ON m.principal_id=b.principal_id
        WHERE (
            (b.provider='supabase' AND b.provider_subject=:uid)
            OR (b.provider='firebase' AND b.firebase_uid=:uid)
        )
          AND m.organization_id=:org AND b.status='active'
        ORDER BY CASE WHEN m.status='active' THEN 0 ELSE 1 END
        LIMIT 1"""), {"uid": uid, "org": organization_id}).mappings().first()

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
        if not actor or actor["status"] != "active" or not target or target["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        actor_assignments = _active_assigned_role_rows(db, workspace_id, str(actor["principal_id"]))
        actor_roles = {str(row["role_id"]) for row in actor_assignments}
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an active Organization Owner or Branch Head can change role assignments.")
        if canonical == "organization_owner" and "organization_owner" not in actor_roles:
            raise AuthzError("Only an Organization Owner can assign the Organization Owner role.")
        if canonical == "branch_head" and "organization_owner" not in actor_roles:
            raise AuthzError("Only an Organization Owner can appoint a Branch Head.")

        target_roles = set(db.execute(text("""
            SELECT role_id FROM member_roles
            WHERE organization_id=:org AND principal_id=:principal
        """), {"org": workspace_id, "principal": target["principal_id"]}).scalars().all())
        if "organization_owner" not in actor_roles:
            actor_level = max((ROLE_LEVELS.get(role, 0) for role in actor_roles), default=0)
            target_level = max((ROLE_LEVELS.get(role, 0) for role in target_roles), default=0)
            if target_level >= actor_level:
                raise AuthzError("You cannot change roles for an equal or higher role.")
            branch_ids = {
                str(row["location_id"]) for row in actor_assignments
                if row["role_id"] == "branch_head" and row["location_id"] is not None
            }
            if len(branch_ids) != 1:
                raise AuthzError("An unambiguous active Branch Head branch assignment is required.")
            target_scope = db.execute(text("""
                SELECT 1
                FROM organizational_assignments target_oa
                JOIN organization_members target_member
                  ON target_member.organization_id=target_oa.organization_id
                 AND target_member.principal_id=target_oa.principal_id
                JOIN locations l
                  ON l.organization_id=target_oa.organization_id AND l.location_id=target_oa.location_id
                WHERE target_oa.organization_id=:org AND target_member.workspace_id=:workspace
                  AND target_oa.principal_id=:target AND target_oa.location_id=:location
                  AND target_oa.status='active' AND l.status='active'
                LIMIT 1
            """), {"org": workspace_id, "workspace": workspace_id,
                    "target": target["principal_id"], "location": next(iter(branch_ids))}).scalar_one_or_none()
            if target_scope is None:
                raise AuthzError("The target member is outside your branch.")

        role_exists = db.execute(text("SELECT 1 FROM roles WHERE role_id=:role"),
                                 {"role": canonical}).scalar_one_or_none()
        if not role_exists:
            raise AuthzError("Role is not part of the organization RBAC model.")
        if canonical == "organization_owner" and not enabled:
            _guard_last_owner(db, workspace_id, target["principal_id"])
        if enabled:
            db.execute(text("""
                INSERT INTO member_roles(organization_id, principal_id, role_id)
                VALUES (:org,:principal,:role) ON CONFLICT DO NOTHING
            """), {"org": workspace_id, "principal": target["principal_id"], "role": canonical})
        else:
            db.execute(text("""
                DELETE FROM member_roles
                WHERE organization_id=:org AND principal_id=:principal AND role_id=:role
            """), {"org": workspace_id, "principal": target["principal_id"], "role": canonical})
    return True

def upsert_role(claims: dict[str, Any], workspace_id: str, role_id: str,
                name: str, permissions: list[str]) -> bool:
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 100:
        raise ValueError("Invalid role name.")
    from .schema import clean_permissions
    permissions = clean_permissions(permissions)
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        if not actor or actor["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        actor_roles = {
            str(row["role_id"])
            for row in _active_assigned_role_rows(db, workspace_id, str(actor["principal_id"]))
        }
        if "organization_owner" not in actor_roles:
            raise AuthzError("Only an active Organization Owner can manage RBAC role definitions.")
        role = db.execute(text("SELECT system FROM roles WHERE role_id=:role"),
                          {"role": role_id}).scalar_one_or_none()
        if role is True:
            raise AuthzError("System roles cannot be overwritten.")
        db.execute(text("""
            INSERT INTO roles(role_id,name,system) VALUES (:role,:name,FALSE)
            ON CONFLICT (role_id) DO UPDATE SET name=EXCLUDED.name
        """), {"role": role_id, "name": name.strip()})
        db.execute(text("DELETE FROM role_permissions WHERE role_id=:role"), {"role": role_id})
        for permission in permissions:
            db.execute(text("""
                INSERT INTO role_permissions(role_id,permission_id)
                VALUES (:role,:permission)
            """), {"role": role_id, "permission": permission})
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
        if not actor or actor["status"] != "active" or not target or target["status"] != "active":
            raise AuthzError("Workspace authorization denied.")
        if str(target.get("employee_id") or "") != str(employee_id or ""):
            raise AuthzError("Employee ID does not match the authenticated organization's member record.")

        actor_assignments = _active_assigned_role_rows(db, workspace_id, str(actor["principal_id"]))
        actor_roles = {str(row["role_id"]) for row in actor_assignments}
        if not actor_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an active Organization Owner or Branch Head can approve an employee.")

        target_assignments = _active_assigned_role_rows(db, workspace_id, str(target["principal_id"]))
        if not target_assignments:
            raise AuthzError("The target must have an active organizational assignment.")
        target_roles = {str(row["role_id"]) for row in target_assignments}
        if target_roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Organization Owner and Branch Head accounts are not employee approval targets.")
        if "organization_owner" not in actor_roles:
            branch_ids = {
                str(row["location_id"]) for row in actor_assignments
                if row["role_id"] == "branch_head" and row["location_id"] is not None
            }
            if len(branch_ids) != 1:
                raise AuthzError("An unambiguous active Branch Head branch assignment is required.")
            branch_id = next(iter(branch_ids))
            if not any(str(row["location_id"] or "") == branch_id for row in target_assignments):
                raise AuthzError("The target member is outside your branch.")

        db.execute(text("""
            INSERT INTO approved_employees
                (organization_id, workspace_id, employee_id, principal_id, status,
                 approved_by_principal_id, approved_at)
            VALUES (:org,:workspace,:employee,:principal,'active',:actor,now())
            ON CONFLICT (organization_id, employee_id) DO UPDATE SET
              workspace_id=EXCLUDED.workspace_id, principal_id=EXCLUDED.principal_id,
              status='active', approved_by_principal_id=EXCLUDED.approved_by_principal_id,
              approved_at=now()
        """), {"org": workspace_id, "workspace": workspace_id,
                "employee": employee_id, "principal": target["principal_id"],
                "actor": actor["principal_id"]})
    return True


def set_delegation(claims: dict[str, Any], workspace_id: str, team_lead_uid: str,
                   member_ids: list[str], dataset_ids: list[str], permissions: list[str],
                   expires_at: int | None) -> dict[str, Any]:
    """Authorize one Team Lead to create copies of a selected dataset set."""
    allowed = {"dataset.create_working_copy"}
    if set(permissions or []) != allowed:
        raise ValueError("Delegation must grant dataset.create_working_copy only.")
    expiry = datetime.fromtimestamp(expires_at / 1000, tz=timezone.utc) if expires_at is not None else None
    if expiry is not None and expiry <= datetime.now(timezone.utc):
        raise ValueError("Delegation expiry must be in the future.")

    delegation_id = _id("dlg")
    with SessionLocal.begin() as db:
        actor = _principal_for_claims(db, claims, workspace_id)
        lead = _principal_for_uid(db, team_lead_uid, workspace_id)
        if not actor or actor["status"] != "active" or not lead or lead["status"] != "active":
            raise AuthzError("Workspace authorization denied.")

        actor_id = str(actor["principal_id"])
        lead_id = str(lead["principal_id"])
        actor_assignments = _active_assigned_role_rows(db, workspace_id, actor_id)
        roles = {str(row["role_id"]) for row in actor_assignments}
        if not roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only an active Organization Owner or Branch Head can manage delegations.")
        lead_assignments = _active_assigned_role_rows(db, workspace_id, lead_id)
        if not any(row["role_id"] == "team_lead" for row in lead_assignments):
            raise AuthzError("Delegation target must be an active Team Lead.")

        if "organization_owner" in roles:
            scoped_location = None
        else:
            issuer_role = "branch_head" if "branch_head" in roles else "manager"
            actor_locations = {
                str(row["location_id"]) for row in actor_assignments
                if row["role_id"] == issuer_role and row.get("location_id") is not None
            }
            if len(actor_locations) != 1:
                raise AuthzError("An unambiguous active branch assignment is required.")
            scoped_location = next(iter(actor_locations))
            if not any(str(row.get("location_id") or "") == scoped_location for row in lead_assignments):
                raise AuthzError("The Team Lead is outside your branch.")

        scoped_members = []
        for uid in sorted(set(member_ids or [])):
            member = _principal_for_uid(db, uid, workspace_id)
            if not member or member["status"] != "active":
                raise AuthzError("Delegation members must be active organization members.")
            member_id = str(member["principal_id"])
            assignments = _active_assigned_role_rows(db, workspace_id, member_id)
            member_roles = {str(row["role_id"]) for row in assignments}
            if not assignments or member_roles.intersection({
                "organization_owner", "branch_head", "manager", "team_lead", "external_viewer"
            }):
                raise AuthzError("Only ordinary assigned employees may be included in Team Lead scope.")
            if scoped_location and not any(str(row.get("location_id") or "") == scoped_location for row in assignments):
                raise AuthzError("A delegation member is outside your branch.")
            approved = db.execute(text("""
                SELECT 1 FROM approved_employees
                WHERE workspace_id=:workspace AND principal_id=:principal AND status='active'
            """), {"workspace": workspace_id, "principal": member_id}).scalar_one_or_none()
            if not approved:
                raise AuthzError("Delegation members must be approved employees.")
            scoped_members.append(member_id)

        clean_dataset_ids = sorted(set(dataset_ids or []))
        for dataset_id in clean_dataset_ids:
            row = db.execute(text("""
                SELECT location_id, status, protected_original
                FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:dataset
                FOR SHARE
            """), {"org": workspace_id, "dataset": dataset_id}).mappings().first()
            resource = db.execute(text("""
                SELECT 1 FROM authorization_resources
                WHERE organization_id=:org AND resource_id=:dataset AND resource_type='dataset'
            """), {"org": workspace_id, "dataset": dataset_id}).scalar_one_or_none()
            if not row or row["status"] != "active" or not row["protected_original"] or not row["location_id"] or not resource:
                raise AuthzError("Delegations require active published, branch-scoped originals.")
            if scoped_location and str(row["location_id"]) != scoped_location:
                raise AuthzError("A delegated dataset is outside your branch.")

        db.execute(text("""
            INSERT INTO delegations
                (delegation_id, organization_id, workspace_id, team_lead_principal_id,
                 member_principal_ids, dataset_ids, permissions, expires_at, status)
            VALUES (:id,:org,:workspace,:lead,CAST(:members AS jsonb),CAST(:datasets AS jsonb),
                    CAST(:permissions AS jsonb),:expires,'active')
        """), {"id": delegation_id, "org": workspace_id, "workspace": workspace_id,
                "lead": lead_id, "members": json.dumps(scoped_members),
                "datasets": json.dumps(clean_dataset_ids),
                "permissions": json.dumps(["dataset.create_working_copy"]), "expires": expiry})
        db.execute(text("""
            INSERT INTO audit_events
              (event_id, organization_id, actor_principal_id, action, outcome, metadata)
            VALUES (:event, :org, :actor, 'dataset.copy_delegation.create', 'succeeded',
                    CAST(:metadata AS jsonb))
        """), {"event": _id("evt"), "org": workspace_id, "actor": actor_id,
                "metadata": json.dumps({
                    "delegation_id": delegation_id, "team_lead_principal_id": lead_id,
                    "dataset_ids": clean_dataset_ids, "member_principal_ids": scoped_members,
                    "location_id": scoped_location,
                })})
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

        members = db.execute(text(f"""SELECT b.provider_subject AS uid, m.principal_id,
            m.employee_id, m.status,
            COALESCE(array_agg(DISTINCT mr.role_id) FILTER (WHERE mr.role_id IS NOT NULL), ARRAY[]::text[]) AS role_ids,
            COALESCE(array_agg(DISTINCT oa.location_id) FILTER (WHERE oa.location_id IS NOT NULL), ARRAY[]::text[]) AS location_ids
            FROM organization_members m
            JOIN identity_bindings b
              ON b.principal_id=m.principal_id AND b.provider='supabase' AND b.status='active'
            LEFT JOIN member_roles mr
              ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
            LEFT JOIN organizational_assignments oa
              ON oa.organization_id=m.organization_id AND oa.principal_id=m.principal_id AND oa.status='active'
            WHERE m.organization_id=:org AND {member_scope}
            GROUP BY b.provider_subject,m.principal_id,m.employee_id,m.status"""), member_params).mappings().all()

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
        datasets = db.execute(text(f"""SELECT da.dataset_id, da.location_id, da.protected_original,
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
            working_copy_scope = """(
                EXISTS (
                    SELECT 1 FROM working_copy_assignments wca
                    WHERE wca.organization_id=wc.organization_id
                      AND wca.working_copy_id=wc.working_copy_id
                      AND wca.principal_id=:actor AND wca.status='active'
                )
                OR EXISTS (
                    SELECT 1 FROM resource_grants rg
                    WHERE rg.organization_id=wc.organization_id
                      AND rg.resource_id=wc.working_copy_id
                      AND rg.principal_id=:actor
                      AND rg.permissions @> CAST('["working_copy.view"]' AS jsonb)
                )
            )"""
        copy_source_fields = (
            "wc.source_dataset_id, wc.source_version,"
            if organization_wide or "branch_head" in actor_roles or "manager" in actor_roles
            else ""
        )
        copy_creator_field = (
            "wc.created_by_principal_id,"
            if organization_wide or "branch_head" in actor_roles or "manager" in actor_roles
            else ""
        )
        working_copies = db.execute(text(f"""SELECT wc.working_copy_id,
            {copy_source_fields} wc.version, wc.status, {copy_creator_field}
            wc.created_at
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
        approved = db.execute(text(f"""SELECT b.provider_subject AS uid, a.principal_id, a.employee_id, a.status
            FROM approved_employees a JOIN identity_bindings b
              ON b.principal_id=a.principal_id AND b.provider='supabase' AND b.status='active'
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
        # member_roles is a role catalogue, not proof of current authority.
        # Every role, including Organization Owner, must have a live assignment.
        # Owner assignments are organization-wide and may have no location;
        # branch/section roles additionally require their active scope.
        roles = db.execute(text("""SELECT DISTINCT mr.role_id FROM member_roles mr
            JOIN organization_members current_m
              ON current_m.organization_id=mr.organization_id
             AND current_m.principal_id=mr.principal_id
             AND current_m.status='active'
             AND current_m.workspace_id=:workspace
            WHERE mr.organization_id=:organization AND mr.principal_id=:principal
              AND EXISTS (
                SELECT 1
                FROM organizational_assignments oa
                WHERE oa.organization_id=mr.organization_id
                  AND oa.principal_id=mr.principal_id
                  AND oa.role_id=mr.role_id
                  AND oa.status='active'
                  AND (
                    mr.role_id='organization_owner'
                    OR (
                      oa.location_id IS NOT NULL
                      AND EXISTS (
                        SELECT 1 FROM locations l
                        WHERE l.organization_id=oa.organization_id
                          AND l.location_id=oa.location_id
                          AND l.status='active'
                      )
                      AND (
                        oa.section_id IS NULL
                        OR EXISTS (
                          SELECT 1 FROM sections s
                          WHERE s.organization_id=oa.organization_id
                            AND s.section_id=oa.section_id
                            AND s.status='active'
                        )
                      )
                    )
                  )
              )
            ORDER BY mr.role_id"""),
                           {"organization": selected["organization_id"],
                            "principal": selected["principal_id"],
                            "workspace": selected["workspace_id"]}).scalars().all()
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
    # A request without a dataset ID is a new original upload. Apply the same
    # role, active-branch and explicit Manager-grant policy as version writes.
    if action in {"dataset.upload", "dataset.upload_original"} and not resource_id:
        return authorize_dataset_upload_scope(claims, workspace_id)

    # Dataset operations have stricter resource/branch policy than workspace
    # permission bits; use the same decision point as managed-dataset APIs.
    if action.startswith("dataset.") and resource_id:
        return authorize_dataset(claims, workspace_id, resource_id, action)
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
        if not resource:
            raise AuthzError("Resource is not accessible.")

        # Analysis against persisted data must inherit the authoritative
        # dataset/working-copy boundary. A generic resource grant alone must
        # never let a copy-only role analyze an original dataset.
        if action == "analysis.run" and resource["resource_type"] == "dataset":
            return {
                **authorize_dataset(claims, workspace_id, resource_id, "dataset.view_original"),
                "action": action,
            }
        if action == "analysis.run" and resource["resource_type"] == "working_copy":
            return {
                **authorize_working_copy(claims, workspace_id, resource_id, "working_copy.view"),
                "action": action,
            }

        with SessionLocal() as db:
            grant = db.execute(
                text("""SELECT permissions
                        FROM resource_grants
                        WHERE organization_id=:org
                          AND resource_id=:resource
                          AND principal_id=:principal"""),
                {"org": organization_id, "resource": resource_id,
                 "principal": context["principal_id"]},
            ).scalar_one_or_none()
        if action not in set(grant or []):
            raise AuthzError("Permission denied for this resource.")
    return {"authorized": True, "workspace_id": resolved_workspace_id, "organization_id": organization_id,
            "action": action, "principal_id": context["principal_id"]}

def set_resource_grant(claims: dict[str, Any], workspace_id: str, resource_id: str,
                       target_uid: str, permissions: list[str],
                       required_permission: str | None = None) -> bool:
    """Grant scoped resource permissions without allowing original-data bypasses."""
    actor = authorization_context(claims, workspace_id)
    if not actor.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    capability = required_permission or "users.manage"
    if capability not in actor["permissions"]:
        raise AuthzError("Workspace authorization denied.")
    actor_roles = set(actor.get("role_ids", []))
    if not actor_roles.intersection({"organization_owner", "branch_head"}):
        raise AuthzError("Only an Organization Owner or Branch Head can grant resource access.")

    from .schema import clean_permissions
    permissions = clean_permissions(permissions)
    organization_id = str(actor["organization_id"])
    resolved_workspace_id = str(actor["workspace_id"])
    actor_principal_id = str(actor["principal_id"])

    with SessionLocal.begin() as db:
        target = db.execute(text("""
            SELECT b.principal_id, m.employee_id
            FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE ((b.provider='supabase' AND b.provider_subject=:uid)
                OR (b.provider='firebase' AND b.firebase_uid=:uid))
              AND m.organization_id=:org AND m.workspace_id=:workspace
              AND m.status='active' AND b.status='active'
            LIMIT 1
        """), {"uid": target_uid, "org": organization_id,
                "workspace": resolved_workspace_id}).mappings().first()
        if not target:
            raise AuthzError("Grant target is not an active workspace member.")

        resource = db.execute(text("""
            SELECT resource_type FROM authorization_resources
            WHERE organization_id=:org AND resource_id=:resource
        """), {"org": organization_id, "resource": resource_id}).mappings().first()
        if not resource:
            raise AuthzError("Resource is not accessible.")

        target_assignments = _active_assigned_role_rows(
            db, resolved_workspace_id, str(target["principal_id"])
        )
        target_roles = {str(row["role_id"]) for row in target_assignments}
        scoped_dataset = None

        if resource["resource_type"] == "dataset":
            scoped_dataset = db.execute(text("""
                SELECT location_id, status, protected_original
                FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:resource
            """), {"org": organization_id, "resource": resource_id}).mappings().first()
            if (not scoped_dataset or scoped_dataset["status"] != "active"
                    or not scoped_dataset["protected_original"] or not scoped_dataset["location_id"]):
                raise AuthzError("Only an active, branch-scoped original dataset can be shared.")
            location = str(scoped_dataset["location_id"])
            allowed_permissions = {"dataset.view_original", "dataset.create_working_copy"}
            if any(permission not in allowed_permissions for permission in permissions):
                raise AuthzError("Dataset grants may only provide explicit read access or copy creation.")
            if "dataset.create_working_copy" in permissions:
                if set(permissions) != {"dataset.create_working_copy"}:
                    raise AuthzError("Copy-only grants must not include original-dataset permissions.")
                if not target_roles or target_roles.intersection({
                    "organization_owner", "branch_head", "manager", "external_viewer"
                }):
                    raise AuthzError("Copy-only grants can be issued only to Team Leads and ordinary employees.")
                if not any(str(row.get("location_id") or "") == location for row in target_assignments):
                    raise AuthzError("The copy recipient must be actively assigned to the dataset's branch.")
            if "dataset.view_original" in permissions:
                if not target_roles.intersection({
                    "organization_owner", "branch_head", "manager", "external_viewer"
                }):
                    raise AuthzError("Team Leads and employees cannot receive original-dataset access.")
                if not target_roles.intersection({"organization_owner", "external_viewer"}):
                    if not any(str(row.get("location_id") or "") == location for row in target_assignments):
                        raise AuthzError("Original-dataset grants must remain within the recipient's branch.")

        elif resource["resource_type"] == "working_copy":
            scoped_dataset = db.execute(text("""
                SELECT da.location_id, da.status
                FROM working_copy_authorization wc
                JOIN dataset_authorization da
                  ON da.organization_id=wc.organization_id AND da.dataset_id=wc.source_dataset_id
                WHERE wc.organization_id=:org AND wc.working_copy_id=:resource
                  AND wc.status='active' AND da.status='active'
            """), {"org": organization_id, "resource": resource_id}).mappings().first()
            if not scoped_dataset or not scoped_dataset["location_id"]:
                raise AuthzError("Working copy must resolve to an active branch-scoped source dataset.")
            if any(permission not in {
                "working_copy.view", "working_copy.modify", "working_copy.delete"
            } for permission in permissions):
                raise AuthzError("Working-copy grants may only provide copy-level view, modify, or delete access.")
            if not target_roles or target_roles.intersection({
                "organization_owner", "branch_head", "manager", "external_viewer"
            }):
                raise AuthzError("Working copies may only be assigned to Team Leads or ordinary employees.")
            if not any(str(row.get("location_id") or "") == str(scoped_dataset["location_id"])
                       for row in target_assignments):
                raise AuthzError("The working-copy recipient must be actively assigned to the source branch.")
        elif "organization_owner" not in actor_roles:
            raise AuthzError("Branch Heads may grant access only to branch-scoped datasets and working copies.")

        if "external_viewer" in target_roles and (
            resource["resource_type"] != "dataset"
            or any(permission != "dataset.view_original" for permission in permissions)
        ):
            raise AuthzError("External Viewers may receive read-only grants for explicitly shared datasets only.")

        # Branch Heads can only grant resources inside their own active branch.
        if "organization_owner" not in actor_roles:
            branch_locations = {
                str(value) for value in db.execute(text("""
                    SELECT oa.location_id
                    FROM organizational_assignments oa
                    JOIN organization_members m
                      ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                    JOIN member_roles mr
                      ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                     AND mr.role_id='branch_head'
                    JOIN locations l
                      ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                    WHERE oa.organization_id=:org AND oa.principal_id=:actor
                      AND oa.role_id='branch_head' AND oa.status='active'
                      AND m.workspace_id=:workspace AND m.status='active'
                      AND l.status='active' AND oa.location_id IS NOT NULL
                """), {"org": organization_id, "actor": actor_principal_id,
                        "workspace": resolved_workspace_id}).scalars().all()
            }
            if not scoped_dataset or str(scoped_dataset["location_id"]) not in branch_locations:
                raise AuthzError("The resource belongs to a branch outside your Branch Head scope.")

        db.execute(text("""
            INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :resource, :principal, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions
        """), {"org": organization_id, "resource": resource_id,
                "principal": target["principal_id"], "permissions": json.dumps(permissions)})
    return True

def register_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str | None,
                     owner_uid: str, protected: bool = True,
                     location_id: str | None = None) -> dict[str, Any]:
    """Register authorization for a newly persisted original dataset only.

    This endpoint is not an ACL-reassignment mechanism. The authenticated actor
    must be the original uploader, the dataset must already exist in this
    organization, and the active upload authority must cover the exact branch.
    Existing authorization records cannot be overwritten through registration.
    """
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    if not protected:
        raise AuthzError("Managed original datasets must be registered as protected originals.")

    actor = str(context["principal_id"])
    organization_id = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    dataset_id = str(dataset_id or "").strip()
    if not dataset_id:
        raise ValueError("A persisted dataset ID is required.")
    provider, subject = _identity(claims)

    # The shared upload policy enforces Owner/Branch Head authority or an
    # explicit Manager grant for the exact branch.
    upload_context = authorize_dataset_upload_scope(
        claims, workspace_id, location_id=location_id
    )
    owner_location = str(upload_context["location_id"])
    upload_role = str(upload_context["upload_role_id"])

    with SessionLocal.begin() as db:
        owner = db.execute(text("""SELECT b.principal_id
            FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE b.provider=:provider AND b.provider_subject=:owner_uid
              AND m.organization_id=:org AND m.workspace_id=:workspace
              AND m.status='active' AND b.status='active'"""),
            {"provider": provider, "owner_uid": str(owner_uid),
             "org": organization_id, "workspace": resolved_workspace_id}).scalar_one_or_none()
        if not owner or str(owner) != actor:
            raise AuthzError("Only the authenticated uploader can register an original dataset.")

        persisted = db.execute(text("""
            SELECT dataset_id FROM datasets
            WHERE organization_id=:org AND dataset_id=:dataset
              AND uploaded_by=:actor AND status='processing'
              AND current_version_id IS NULL
            FOR UPDATE
        """), {"org": organization_id, "dataset": dataset_id,
                "actor": actor}).scalar_one_or_none()
        if persisted is None:
            raise AuthzError(
                "Only the authenticated uploader may register their own unpublished dataset before first publication."
            )

        existing_resource = db.execute(text("""
            SELECT 1 FROM authorization_resources
            WHERE organization_id=:org AND resource_id=:dataset
            FOR UPDATE
        """), {"org": organization_id, "dataset": dataset_id}).scalar_one_or_none()
        existing_dataset_acl = db.execute(text("""
            SELECT 1 FROM dataset_authorization
            WHERE organization_id=:org AND dataset_id=:dataset
            FOR UPDATE
        """), {"org": organization_id, "dataset": dataset_id}).scalar_one_or_none()
        if existing_resource is not None or existing_dataset_acl is not None:
            raise AuthzError("This dataset already has an authorization record; registration cannot overwrite it.")

        # Revalidate the upload authority while holding transaction locks so a
        # branch reassignment or grant revocation cannot race registration.
        if upload_role == "organization_owner":
            active_authority = db.execute(text("""
                SELECT oa.assignment_id
                FROM organizational_assignments oa
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                JOIN member_roles mr
                  ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                 AND mr.role_id='organization_owner'
                JOIN role_permissions rp
                  ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
                JOIN locations l
                  ON l.organization_id=oa.organization_id AND l.location_id=:location
                 AND l.status='active'
                WHERE oa.organization_id=:org AND oa.principal_id=:actor
                  AND oa.role_id='organization_owner' AND oa.status='active'
                  AND m.workspace_id=:workspace AND m.status='active'
                LIMIT 1 FOR SHARE OF oa, m, mr, rp, l
            """), {"org": organization_id, "actor": actor,
                    "workspace": resolved_workspace_id, "location": owner_location}).scalar_one_or_none()
        elif upload_role == "branch_head":
            active_authority = db.execute(text("""
                SELECT oa.assignment_id
                FROM organizational_assignments oa
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                JOIN member_roles mr
                  ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                 AND mr.role_id='branch_head'
                JOIN role_permissions rp
                  ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
                JOIN locations l
                  ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                 AND l.status='active'
                WHERE oa.organization_id=:org AND oa.principal_id=:actor
                  AND oa.location_id=:location AND oa.role_id='branch_head'
                  AND oa.status='active' AND m.workspace_id=:workspace AND m.status='active'
                LIMIT 1 FOR SHARE OF oa, m, mr, rp, l
            """), {"org": organization_id, "actor": actor,
                    "workspace": resolved_workspace_id, "location": owner_location}).scalar_one_or_none()
        else:
            raise AuthzError("Only an Organization Owner or Branch Head may register an original dataset.")
        if active_authority is None:
            raise AuthzError("The active Owner or Branch Head upload authority is no longer valid.")

        db.execute(text("""INSERT INTO authorization_resources
            (organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :dataset, 'dataset', :owner)"""),
            {"org": organization_id, "dataset": dataset_id, "owner": actor})
        db.execute(text("""INSERT INTO dataset_authorization
            (organization_id, dataset_id, owner_principal_id, protected_original, location_id)
            VALUES (:org, :dataset, :owner, TRUE, :location)"""),
            {"org": organization_id, "dataset": dataset_id,
             "owner": actor, "location": owner_location})
        db.execute(text("""INSERT INTO resource_grants
            (organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :dataset, :owner,
                    CAST(:permissions AS jsonb))"""),
            {"org": organization_id, "dataset": dataset_id, "owner": actor,
             "permissions": '["dataset.view_original","dataset.create_working_copy","dataset.manage_acl"]'})

    return {"dataset_id": dataset_id, "organization_id": organization_id,
            "workspace_id": resolved_workspace_id}


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
    if not roles.intersection({"organization_owner", "branch_head", "manager"}):
        raise AuthzError("Only an Owner, Branch Head, or Manager can review copy requests.")
    org, workspace, actor = (
        str(context["organization_id"]), str(context["workspace_id"]),
        str(context["principal_id"]),
    )
    with SessionLocal.begin() as db:
        req = db.execute(text("""
            SELECT * FROM authorization_requests
            WHERE organization_id=:org AND workspace_id=:workspace
              AND request_id=:request AND status='pending'
            FOR UPDATE
        """), {"org": org, "workspace": workspace, "request": request_id}).mappings().first()
        if not req:
            raise AuthzError("Pending copy request not found.")
        if "organization_owner" not in roles:
            issuer_role = "branch_head" if "branch_head" in roles else "manager"
            issuer = db.execute(text("""
                SELECT 1 FROM organizational_assignments oa
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                JOIN member_roles mr
                  ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                 AND mr.role_id=oa.role_id
                JOIN locations l ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                WHERE oa.organization_id=:org AND oa.principal_id=:actor
                  AND oa.location_id=:location AND oa.role_id=:role
                  AND oa.status='active' AND m.workspace_id=:workspace AND m.status='active'
                  AND l.status='active'
                LIMIT 1
            """), {"org": org, "workspace": workspace, "actor": actor,
                    "location": req["location_id"], "role": issuer_role}).scalar_one_or_none()
            if not issuer:
                raise AuthzError("This request belongs to a branch outside your scope.")

        requester = db.execute(text("""
            SELECT 1
            FROM organization_members m
            JOIN organizational_assignments oa
              ON oa.organization_id=m.organization_id AND oa.principal_id=m.principal_id
            JOIN locations l ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
            WHERE m.organization_id=:org AND m.workspace_id=:workspace
              AND m.principal_id=:requester AND m.status='active'
              AND oa.location_id=:location AND oa.status='active' AND l.status='active'
            LIMIT 1
        """), {"org": org, "workspace": workspace,
                "requester": req["requester_principal_id"], "location": req["location_id"]}).scalar_one_or_none()
        if not requester:
            raise AuthzError("The requester is no longer actively assigned to this branch.")

        if not approve:
            db.execute(text("""
                UPDATE authorization_requests
                SET status='rejected', reviewed_by_principal_id=:reviewer,
                    reviewed_at=now(), updated_at=now()
                WHERE organization_id=:org AND request_id=:request AND status='pending'
            """), {"org": org, "reviewer": context["principal_id"], "request": request_id})
            return {"request_id": request_id, "status": "rejected"}

    copy = create_working_copy(claims, workspace, str(req["dataset_id"]), None, None)
    with SessionLocal.begin() as db:
        db.execute(text("""
            INSERT INTO working_copy_assignments
                (working_copy_id, organization_id, principal_id, assigned_by_principal_id)
            VALUES (:copy,:org,:principal,:assigner)
            ON CONFLICT (organization_id, working_copy_id, principal_id)
            DO UPDATE SET assigned_by_principal_id=EXCLUDED.assigned_by_principal_id,
                          status='active', updated_at=now()
        """), {"copy": copy["working_copy_id"], "org": org,
                "principal": req["requester_principal_id"], "assigner": actor})
        db.execute(text("""
            UPDATE authorization_requests
            SET status='approved', reviewed_by_principal_id=:reviewer, reviewed_at=now(),
                resulting_working_copy_id=:copy, updated_at=now()
            WHERE organization_id=:org AND request_id=:request AND status='pending'
        """), {"org": org, "reviewer": actor, "copy": copy["working_copy_id"], "request": request_id})
    return {"request_id": request_id, "status": "approved", "working_copy": copy}


def assign_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, target_uid: str) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner", "branch_head"}):
        raise AuthzError("Only a Branch Head or Organization Owner can assign working copies.")

    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    actor = str(context["principal_id"])
    with SessionLocal.begin() as db:
        source = db.execute(text("""
            SELECT wc.source_dataset_id, da.location_id
            FROM working_copy_authorization wc
            JOIN dataset_authorization da
              ON da.organization_id=wc.organization_id
             AND da.dataset_id=wc.source_dataset_id AND da.status='active'
            WHERE wc.organization_id=:org AND wc.working_copy_id=:copy AND wc.status='active'
            FOR UPDATE OF wc
        """), {"org": org, "copy": working_copy_id}).mappings().first()
        if not source or not source["location_id"]:
            raise AuthzError("Working copy or its active branch source is not accessible.")
        location = str(source["location_id"])

        if "organization_owner" not in roles:
            issuer_role = "branch_head" if "branch_head" in roles else "manager"
            issuer = db.execute(text("""
                SELECT 1
                FROM organizational_assignments oa
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                JOIN member_roles mr
                  ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                 AND mr.role_id=oa.role_id
                JOIN locations l
                  ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                WHERE oa.organization_id=:org AND oa.principal_id=:actor
                  AND oa.location_id=:location AND oa.role_id=:role
                  AND oa.status='active' AND m.workspace_id=:workspace
                  AND m.status='active' AND l.status='active'
                LIMIT 1 FOR SHARE OF oa, m, mr, l
            """), {"org": org, "actor": actor, "location": location,
                    "role": issuer_role, "workspace": workspace}).scalar_one_or_none()
            if issuer is None:
                raise AuthzError("The working copy is outside your active branch scope.")

        target = _principal_for_uid(db, target_uid, org)
        if not target or target["status"] != "active":
            raise AuthzError("Assignment target is not an active member.")
        target_id = str(target["principal_id"])
        target_assignments = _active_assigned_role_rows(db, workspace, target_id)
        target_roles = {str(item["role_id"]) for item in target_assignments}
        if not target_assignments:
            raise AuthzError("Assignment target must have an active organizational assignment.")
        if target_roles.intersection({
            "organization_owner", "branch_head", "manager", "external_viewer"
        }):
            raise AuthzError("Working copies may be assigned only to Team Leads and ordinary employees.")
        if not any(str(item.get("location_id") or "") == location for item in target_assignments):
            raise AuthzError("The assignment target must belong to the source dataset's branch.")

        db.execute(text("""
            UPDATE working_copy_assignments SET status='revoked', updated_at=now()
            WHERE organization_id=:org AND working_copy_id=:copy AND status='active'
        """), {"org": org, "copy": working_copy_id})
        # A working copy is a single-principal capability. On reassignment,
        # revoke the prior creator and any previous recipient's resource grant;
        # assignment of a copy must not leave another Team Lead/employee with
        # continuing access to the same snapshot.
        db.execute(text("""
            DELETE FROM resource_grants
            WHERE organization_id=:org AND resource_id=:copy AND principal_id<>:target
        """), {"org": org, "copy": working_copy_id, "target": target_id})
        db.execute(text("""
            INSERT INTO working_copy_assignments
                (working_copy_id, organization_id, principal_id, assigned_by_principal_id)
            VALUES (:copy,:org,:principal,:assigner)
            ON CONFLICT (organization_id, working_copy_id, principal_id)
            DO UPDATE SET assigned_by_principal_id=EXCLUDED.assigned_by_principal_id,
                          status='active', updated_at=now()
        """), {"copy": working_copy_id, "org": org,
                "principal": target_id, "assigner": actor})

    return {"working_copy_id": working_copy_id,
            "assigned_to_principal_id": target_id, "status": "active"}


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



def authorize_dataset_upload_scope(
    claims: dict[str, Any],
    workspace_id: str,
    *,
    location_id: str | None = None,
) -> dict[str, Any]:
    """Authorize publication writes to an original dataset.

    Only Organization Owners and Branch Heads may write originals. Owners can
    write within their organization; Branch Heads must have the dataset.upload
    capability and an active assignment to the exact target branch. Managers
    submit private proposals through dataset_storage.proposals instead.
    """
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")

    roles = set(context.get("role_ids", []))
    if "organization_owner" in roles:
        upload_role = "organization_owner"
    elif "branch_head" in roles:
        upload_role = "branch_head"
    else:
        raise AuthzError("Only an Organization Owner or Branch Head may write an original dataset; Managers must submit a proposal for review.")

    if "dataset.upload" not in set(context.get("permissions", [])):
        raise AuthzError("The active role lacks the dataset.upload permission.")

    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    principal = str(context["principal_id"])
    with SessionLocal() as db:
        if upload_role == "organization_owner":
            allowed_locations = {
                str(value) for value in db.execute(text("""
                    SELECT DISTINCT l.location_id
                    FROM locations l
                    JOIN organizational_assignments oa
                      ON oa.organization_id=l.organization_id
                     AND oa.principal_id=:principal
                     AND oa.role_id='organization_owner' AND oa.status='active'
                    JOIN organization_members m
                      ON m.organization_id=oa.organization_id
                     AND m.principal_id=oa.principal_id
                     AND m.workspace_id=:workspace AND m.status='active'
                    JOIN member_roles mr
                      ON mr.organization_id=m.organization_id
                     AND mr.principal_id=m.principal_id
                     AND mr.role_id='organization_owner'
                    JOIN role_permissions rp
                      ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
                    WHERE l.organization_id=:org AND l.status='active'
                """), {"org": org, "principal": principal, "workspace": workspace}).scalars().all()
            }
        else:
            allowed_locations = {
                str(value) for value in db.execute(text("""
                    SELECT DISTINCT oa.location_id
                    FROM organizational_assignments oa
                    JOIN organization_members m
                      ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                    JOIN member_roles mr
                      ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                     AND mr.role_id='branch_head'
                    JOIN role_permissions rp
                      ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
                    JOIN locations l
                      ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                    WHERE oa.organization_id=:org AND oa.principal_id=:principal
                      AND oa.role_id='branch_head' AND oa.status='active'
                      AND oa.location_id IS NOT NULL AND l.status='active'
                      AND m.status='active' AND m.workspace_id=:workspace
                """), {"org": org, "principal": principal, "workspace": workspace}).scalars().all()
            }

    if location_id is None:
        if not allowed_locations:
            raise AuthzError("An active branch assignment with dataset.upload permission is required.")
        if len(allowed_locations) != 1:
            raise AuthzError("An unambiguous active branch assignment is required.")
        target_location = next(iter(allowed_locations))
    else:
        target_location = str(location_id).strip()
        if not target_location or target_location not in allowed_locations:
            raise AuthzError("You are without an active branch assignment or required upload permission for the selected branch.")

    return {
        **context,
        "authorized": True,
        "permission": "dataset.upload",
        "location_id": target_location,
        "upload_role_id": upload_role,
        "_identity_subject": subject,
    }


def _has_active_branch_assignment(
    organization_id: str,
    workspace_id: str,
    principal_id: str,
    location_id: str | None,
    *,
    role_id: str | None = None,
) -> bool:
    """Return whether this active member has a live assignment in one exact branch."""
    location = str(location_id or "").strip()
    if not location:
        return False
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT 1
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id
             AND m.principal_id=oa.principal_id
            JOIN member_roles mr
              ON mr.organization_id=oa.organization_id
             AND mr.principal_id=oa.principal_id
             AND mr.role_id=oa.role_id
            JOIN locations l
              ON l.organization_id=oa.organization_id
             AND l.location_id=oa.location_id
            WHERE oa.organization_id=:org
              AND oa.principal_id=:principal
              AND oa.location_id=:location
              AND oa.status='active'
              AND m.workspace_id=:workspace
              AND m.status='active'
              AND l.status='active'
              AND (:role_id IS NULL OR oa.role_id=:role_id)
            LIMIT 1
        """), {
            "org": organization_id,
            "workspace": workspace_id,
            "principal": principal_id,
            "location": location,
            "role_id": role_id,
        }).scalar_one_or_none()
    return row is not None


def authorize_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str) -> dict[str, Any]:
    """Enforce immutable-original vs per-principal working-copy permissions."""
    if not action.startswith("dataset."):
        raise ValueError("Dataset authorization requires a dataset capability.")
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")

    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    principal = str(context["principal_id"])
    roles = set(context.get("role_ids", []))
    actor_roles = roles
    with SessionLocal() as db:
        resource = db.execute(text("""
            SELECT resource_type, owner_principal_id
            FROM authorization_resources
            WHERE organization_id=:org AND resource_id=:dataset
        """), {"org": org, "dataset": dataset_id}).mappings().first()
        row = db.execute(text("""
            SELECT protected_original, location_id
            FROM dataset_authorization
            WHERE organization_id=:org AND dataset_id=:dataset AND status='active'
        """), {"org": org, "dataset": dataset_id}).mappings().first()
        grants = db.execute(text("""
            SELECT permissions FROM resource_grants
            WHERE organization_id=:org AND resource_id=:dataset AND principal_id=:principal
        """), {"org": org, "dataset": dataset_id, "principal": principal}).scalar_one_or_none()
        if not resource or resource["resource_type"] != "dataset" or not row:
            raise AuthzError("Dataset is not accessible.")

        dataset_location = str(row["location_id"] or "")
        scope_role = "branch_head" if "branch_head" in roles else "manager"
        scoped_locations: set[str] = set()
        if scope_role in roles:
            scoped_locations = {
                str(value) for value in db.execute(text("""
                    SELECT DISTINCT oa.location_id
                    FROM organizational_assignments oa
                    JOIN organization_members m
                      ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                    JOIN member_roles mr
                      ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                     AND mr.role_id=oa.role_id
                    JOIN locations l
                      ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
                    WHERE oa.organization_id=:org AND oa.principal_id=:principal
                      AND oa.role_id=:role AND oa.status='active'
                      AND oa.location_id IS NOT NULL AND l.status='active'
                      AND m.status='active' AND m.workspace_id=:workspace
                """), {
                    "org": org, "principal": principal, "role": scope_role,
                    "workspace": workspace,
                }).scalars().all()
            }

    grant_permissions = set(grants or [])
    if action in {"dataset.upload", "dataset.upload_original"}:
        if not ({"organization_owner", "branch_head"} & roles):
            raise AuthzError("Only an Organization Owner or Branch Head may modify an original dataset; Managers must submit a proposal for review.")
        if not row["protected_original"] or not dataset_location:
            raise AuthzError("Only a published, branch-scoped original dataset can be modified.")
        upload_context = authorize_dataset_upload_scope(
            claims, workspace_id, location_id=dataset_location
        )
        return {
            **upload_context, "authorized": True,
            "organization_id": org, "workspace_id": workspace,
            "dataset_id": dataset_id, "protected_original": True,
            "location_id": dataset_location,
        }

    if action == "dataset.view_original":
        if "organization_owner" in roles:
            pass
        elif "branch_head" in roles:
            if not dataset_location or dataset_location not in scoped_locations:
                raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
        elif "manager" in roles:
            if not dataset_location or dataset_location not in scoped_locations:
                raise AuthzError("The dataset belongs to a branch outside your Manager scope.")
        elif "external_viewer" in actor_roles:
            if "dataset.view_original" not in grant_permissions:
                raise AuthzError("An explicit read-only dataset grant is required.")
        else:
            raise AuthzError("This role cannot access an original dataset; Only a Manager, Branch Head, Organization Owner, or explicitly shared External Viewer can view it.")

    elif action in {"dataset.delete", "dataset.share", "dataset.manage_acl"}:
        actor_roles = roles
        if "organization_owner" in actor_roles:
            pass
        elif "branch_head" not in actor_roles:
            raise AuthzError("Only an Organization Owner or the active Branch Head for this branch can manage an original dataset.")
        elif not dataset_location or dataset_location not in scoped_locations:
            raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")

    elif action == "dataset.create_working_copy":
        if "organization_owner" in roles:
            pass
        elif "branch_head" in roles or "manager" in roles:
            if not dataset_location or dataset_location not in scoped_locations:
                if "branch_head" in roles:
                    raise AuthzError("The dataset belongs to a branch outside your Branch Head scope.")
                raise AuthzError("The dataset belongs to a branch outside your Manager scope.")
        elif "external_viewer" in roles:
            raise AuthzError("External Viewers are read-only and cannot create working copies.")
        else:
            if not roles or not dataset_location or not _has_active_branch_assignment(
                org, workspace, principal, dataset_location
            ):
                raise AuthzError("Copy access requires an active assignment to the source dataset's branch.")
            if "dataset.create_working_copy" not in grant_permissions:
                delegated = False
                if "team_lead" in roles:
                    with SessionLocal() as db:
                        delegated = db.execute(text("""
                            SELECT 1 FROM delegations d
                            WHERE d.organization_id=:org AND d.workspace_id=:workspace
                              AND d.team_lead_principal_id=:principal AND d.status='active'
                              AND (d.expires_at IS NULL OR d.expires_at > now())
                              AND d.dataset_ids @> CAST(:dataset_ids AS jsonb)
                              AND d.permissions @> CAST(:permissions AS jsonb)
                            LIMIT 1
                        """), {
                            "org": org, "workspace": workspace, "principal": principal,
                            "dataset_ids": json.dumps([dataset_id]),
                            "permissions": json.dumps(["dataset.create_working_copy"]),
                        }).scalar_one_or_none() is not None
                if not delegated:
                    raise AuthzError("This dataset has not been authorized for copying by this user.")

    elif action not in grant_permissions:
        raise AuthzError("Permission denied for this resource.")

    return {
        **context, "authorized": True, "workspace_id": workspace,
        "organization_id": org, "dataset_id": dataset_id,
        "protected_original": bool(row["protected_original"]),
        "location_id": row["location_id"],
    }



def set_dataset_grant(claims: dict[str, Any], workspace_id: str, dataset_id: str,
                      target_uid: str, permissions: list[str]) -> bool:
    """Grant a person copy-only access to one protected original dataset."""
    allowed = {"dataset.create_working_copy"}
    grant_permissions = sorted(set(permissions or []))
    if any(permission not in allowed for permission in grant_permissions):
        raise ValueError("Only dataset.create_working_copy grants can be issued; original-write delegation is forbidden.")
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    actor_roles = set(context.get("role_ids", []))
    if not actor_roles.intersection({"organization_owner", "branch_head", "manager"}):
        raise AuthzError("Only an Organization Owner, Branch Head, or Manager can authorize dataset copies.")

    org, workspace, actor = (
        str(context["organization_id"]), str(context["workspace_id"]),
        str(context["principal_id"]),
    )
    target_uid = str(target_uid or "").strip()
    if not target_uid:
        raise ValueError("A target member is required.")

    with SessionLocal.begin() as db:
        dataset = db.execute(text("""
            SELECT location_id, status, protected_original
            FROM dataset_authorization
            WHERE organization_id=:org AND dataset_id=:dataset
            FOR SHARE
        """), {"org": org, "dataset": dataset_id}).mappings().first()
        resource = db.execute(text("""
            SELECT resource_type FROM authorization_resources
            WHERE organization_id=:org AND resource_id=:dataset
        """), {"org": org, "dataset": dataset_id}).mappings().first()
        if (not dataset or dataset["status"] != "active" or not dataset["location_id"]
                or not dataset["protected_original"] or not resource
                or resource["resource_type"] != "dataset"):
            raise AuthzError("Only an active, published, branch-scoped original can be shared as a copy.")

        target = db.execute(text("""
            SELECT b.principal_id
            FROM identity_bindings b
            JOIN organization_members m ON m.principal_id=b.principal_id
            WHERE ((b.provider='supabase' AND b.provider_subject=:uid)
                OR (b.provider='firebase' AND b.firebase_uid=:uid))
              AND m.organization_id=:org AND m.workspace_id=:workspace
              AND m.status='active' AND b.status='active'
            LIMIT 1 FOR SHARE OF b, m
        """), {"uid": target_uid, "org": org, "workspace": workspace}).scalar_one_or_none()
        if not target:
            raise AuthzError("Grant target is not an active workspace member.")

        assigned = _active_assigned_role_rows(db, workspace, str(target))
        target_roles = {str(item["role_id"]) for item in assigned}
        if not assigned and grant_permissions:
            raise AuthzError("The copy recipient must have an active organizational assignment.")
        if grant_permissions and target_roles.intersection({"organization_owner", "branch_head", "manager", "external_viewer"}):
            raise AuthzError("Copy-only grants can be issued only to Team Leads and ordinary employees.")

        location = str(dataset["location_id"])
        if "organization_owner" not in actor_roles:
            issuer_role = "branch_head" if "branch_head" in actor_roles else "manager"
            actor_locations = {
                str(item["location_id"]) for item in _active_assigned_role_rows(db, workspace, actor)
                if item["role_id"] == issuer_role and item.get("location_id") is not None
            }
            if location not in actor_locations:
                raise AuthzError("The dataset is outside your branch scope.")
        if grant_permissions and not any(str(item.get("location_id") or "") == location for item in assigned):
            raise AuthzError("The copy recipient must be assigned to the dataset's branch.")

        db.execute(text("""
            INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :dataset, :target, CAST(:permissions AS jsonb))
            ON CONFLICT (organization_id, resource_id, principal_id)
            DO UPDATE SET permissions=EXCLUDED.permissions
        """), {"org": org, "dataset": dataset_id, "target": str(target),
                "permissions": json.dumps(grant_permissions)})
        db.execute(text("""
            INSERT INTO audit_events
              (event_id, organization_id, actor_principal_id, action, outcome, metadata)
            VALUES (:event, :org, :actor, 'dataset.copy_grant.create', 'succeeded',
                    CAST(:metadata AS jsonb))
        """), {"event": _id("evt"), "org": org, "actor": actor,
                "metadata": json.dumps({
                    "dataset_id": dataset_id, "target_principal_id": str(target),
                    "location_id": location,
                    "permissions": grant_permissions,
                    "operation": "grant" if grant_permissions else "revoke",
                })})
    return True



def create_working_copy(claims: dict[str, Any], workspace_id: str, dataset_id: str,
                        working_copy_id: str | None, source_version: str | None) -> dict[str, Any]:
    """Create a working copy bound to an immutable published source version."""
    authorize_dataset(claims, workspace_id, dataset_id, "dataset.create_working_copy")
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    org, workspace, principal = (
        str(context["organization_id"]), str(context["workspace_id"]),
        str(context["principal_id"]),
    )
    roles = set(context.get("role_ids", []))
    copy_id = str(working_copy_id or _id("wc"))

    from datasets.repository import DatasetRepository
    with SessionLocal.begin() as db:
        repo = DatasetRepository(db)
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != org or dataset.status != "ready":
            raise AuthzError("Only a published original dataset can be copied.")
        version_id = str(source_version or dataset.current_version_id or "").strip()
        if not version_id:
            raise AuthzError("The original dataset has no published version to copy.")
        version = repo.get_version(dataset_id, version_id)
        if version is None or version.status != "ready":
            raise AuthzError("Only a READY version belonging to this dataset can be copied.")

        if not roles.intersection({"organization_owner", "branch_head", "manager"}):
            grant = db.execute(text("""
                SELECT permissions FROM resource_grants
                WHERE organization_id=:org AND resource_id=:dataset AND principal_id=:principal
                FOR SHARE
            """), {"org": org, "dataset": dataset_id, "principal": principal}).scalar_one_or_none()
            has_copy_grant = "dataset.create_working_copy" in set(grant or [])
            has_delegation = False
            if not has_copy_grant and "team_lead" in roles:
                has_delegation = db.execute(text("""
                    SELECT 1 FROM delegations d
                    WHERE d.organization_id=:org AND d.workspace_id=:workspace
                      AND d.team_lead_principal_id=:principal AND d.status='active'
                      AND (d.expires_at IS NULL OR d.expires_at > now())
                      AND d.dataset_ids @> CAST(:datasets AS jsonb)
                      AND d.permissions @> CAST(:permissions AS jsonb)
                    LIMIT 1 FOR SHARE
                """), {
                    "org": org, "workspace": workspace, "principal": principal,
                    "datasets": json.dumps([dataset_id]),
                    "permissions": json.dumps(["dataset.create_working_copy"]),
                }).scalar_one_or_none() is not None
            if not has_copy_grant and not has_delegation:
                raise PermissionDenied("Copy authorization was revoked or does not include this dataset.")

        db.execute(text("""
            INSERT INTO authorization_resources(organization_id, resource_id, resource_type, owner_principal_id)
            VALUES (:org, :copy, 'working_copy', :principal)
        """), {"org": org, "copy": copy_id, "principal": principal})
        db.execute(text("""
            INSERT INTO working_copy_authorization
                (organization_id, working_copy_id, source_dataset_id, source_version, created_by_principal_id)
            VALUES (:org, :copy, :dataset, :version, :principal)
        """), {"org": org, "copy": copy_id, "dataset": dataset_id,
                "version": version_id, "principal": principal})
        copy_permissions = {
            "working_copy.view", "working_copy.modify", "working_copy.delete"
        }
        db.execute(text("""
            INSERT INTO resource_grants(organization_id, resource_id, principal_id, permissions)
            VALUES (:org, :copy, :principal, CAST(:permissions AS jsonb))
        """), {"org": org, "copy": copy_id, "principal": principal,
                "permissions": json.dumps(sorted(copy_permissions))})
    result = {
        "working_copy_id": copy_id,
        "organization_id": org,
        "workspace_id": workspace,
        "access_mode": "working_copy",
    }
    # Privileged supervisors may see the source pointer. Copy-only users receive
    # only the opaque capability ID; they cannot pivot their client back to the
    # original dataset or version.
    if roles.intersection({"organization_owner", "branch_head", "manager"}):
        result.update({
            "source_dataset_id": dataset_id,
            "source_version": version_id,
        })
    return result


def authorize_working_copy(claims: dict[str, Any], workspace_id: str, working_copy_id: str, action: str) -> dict[str, Any]:
    if action not in {"working_copy.view", "working_copy.modify", "working_copy.delete", "working_copy.assign"}:
        raise ValueError("Invalid working copy action.")
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")

    organization_id = str(context["organization_id"])
    resolved_workspace_id = str(context["workspace_id"])
    principal_id = str(context["principal_id"])
    roles = set(context.get("role_ids", []))
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT wc.source_dataset_id, wc.source_version, wc.version,
                   wc.created_by_principal_id, da.location_id
            FROM working_copy_authorization wc
            JOIN dataset_authorization da
              ON da.organization_id=wc.organization_id
             AND da.dataset_id=wc.source_dataset_id
             AND da.status='active'
            WHERE wc.organization_id=:org AND wc.working_copy_id=:copy
              AND wc.status='active'
        """), {"org": organization_id, "copy": working_copy_id}).mappings().first()
        if not row:
            raise AuthzError("Working copy or its active source is not accessible.")
        assignment = db.execute(text("""
            SELECT 1 FROM working_copy_assignments
            WHERE organization_id=:org AND working_copy_id=:copy
              AND principal_id=:principal AND status='active'
        """), {"org": organization_id, "copy": working_copy_id,
                "principal": principal_id}).scalar_one_or_none()
        grant = db.execute(text("""
            SELECT permissions FROM resource_grants
            WHERE organization_id=:org AND resource_id=:copy AND principal_id=:principal
        """), {"org": organization_id, "copy": working_copy_id,
                "principal": principal_id}).scalar_one_or_none()
    assigned = assignment is not None
    granted = set(grant or [])
    source_location = str(row["location_id"] or "")

    if action == "working_copy.assign":
        if not roles.intersection({"organization_owner", "branch_head"}):
            raise AuthzError("Only a Branch Head or Organization Owner can assign working copies.")
        if "organization_owner" not in roles:
            issuer_role = "branch_head" if "branch_head" in roles else "manager"
            if not _has_active_branch_assignment(
                organization_id, resolved_workspace_id, principal_id, source_location,
                role_id=issuer_role,
            ):
                raise AuthzError("The working copy is outside your active branch scope.")
        return {
            **context, "authorized": True, "organization_id": organization_id,
            "working_copy_id": working_copy_id,
            "source_dataset_id": row["source_dataset_id"],
            "source_version": row["source_version"], "version": row["version"],
            "location_id": row["location_id"],
        }

    if action not in set(context.get("permissions", [])):
        raise AuthzError("This role is not permitted to perform that working-copy operation.")

    if "organization_owner" in roles:
        pass
    elif "branch_head" in roles or "manager" in roles:
        issuer_role = "branch_head" if "branch_head" in roles else "manager"
        if not _has_active_branch_assignment(
            organization_id, resolved_workspace_id, principal_id, source_location,
            role_id=issuer_role,
        ):
            raise AuthzError("The working copy is outside your active branch scope.")
    else:
        if "external_viewer" in roles:
            raise AuthzError("External Viewers cannot access working copies.")
        if not roles or not _has_active_branch_assignment(
            organization_id, resolved_workspace_id, principal_id, source_location
        ):
            raise AuthzError("Working-copy access requires an active assignment to the source branch.")
        if not assigned and action not in granted:
            raise AuthzError("This working copy is assigned to another user or was not shared with you.")

    return {
        **context, "authorized": True, "organization_id": organization_id,
        "working_copy_id": working_copy_id,
        "source_dataset_id": row["source_dataset_id"],
        "source_version": row["source_version"], "version": row["version"],
        "location_id": row["location_id"],
    }


def list_dataset_catalog(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    """List only originals/copy sources the current identity is allowed to act on."""
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise AuthzError("Workspace authorization denied.")
    roles = set(context.get("role_ids", []))
    recognized = {
        "organization_owner", "branch_head", "manager", "team_lead", "employee",
        "data_analyst", "senior_data_analyst", "business_analyst", "data_scientist",
        "data_engineer", "ml_engineer", "analytics_engineer", "bi_developer",
        "data_architect", "data_quality_analyst", "data_governance_analyst",
    }
    if not roles.intersection(recognized):
        return []
    org = str(context["organization_id"])
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT da.dataset_id, ds.dataset_name, ds.original_filename,
                   da.location_id, l.name AS location_name
            FROM dataset_authorization da
            LEFT JOIN datasets ds
              ON ds.organization_id=da.organization_id AND ds.dataset_id=da.dataset_id
            LEFT JOIN locations l
              ON l.organization_id=da.organization_id AND l.location_id=da.location_id
            WHERE da.organization_id=:org AND da.status='active'
              AND da.protected_original=TRUE
            ORDER BY lower(coalesce(ds.dataset_name, da.dataset_id)), da.dataset_id
        """), {"org": org}).mappings().all()

    privileged = roles.intersection({"organization_owner", "branch_head", "manager"})
    action = "dataset.view_original" if privileged else "dataset.create_working_copy"
    output = []
    for row in rows:
        try:
            authorize_dataset(claims, workspace_id, str(row["dataset_id"]), action)
        except AuthzError:
            continue
        output.append({
            "dataset_id": str(row["dataset_id"]),
            "dataset_name": row["dataset_name"] or row["original_filename"] or row["dataset_id"],
            "display_name": row["dataset_name"] or row["original_filename"] or row["dataset_id"],
            "location_id": str(row["location_id"]) if row["location_id"] is not None else None,
            "location_name": row["location_name"],
            "access_mode": "original" if privileged else "copy_only",
        })
    return output






