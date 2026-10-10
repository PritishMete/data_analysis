"""Current user's organization profile operations."""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from core.db import SessionLocal
from .profile_validation import normalize_id_proof_number, validate_profile_fields
from .service import AuthzError


def _identity(claims: dict[str, Any]) -> tuple[str, str]:
    provider = str(claims.get("provider") or "").strip().lower()
    subject = str(claims.get("sub") or claims.get("uid") or "").strip()
    firebase = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    if not provider:
        provider = str(firebase.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase.get("identities") if isinstance(firebase.get("identities"), dict) else {}
    values = identities.get(provider)
    if isinstance(values, list) and values:
        subject = str(values[0])
    return provider, subject


def _auth_time(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _member(db, claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    provider, subject = _identity(claims)
    row = db.execute(text("""
        SELECT p.principal_id, m.employee_id, m.status, m.organization_id, m.workspace_id
        FROM identity_bindings b
        JOIN principals p ON p.principal_id=b.principal_id
        JOIN organization_members m ON m.principal_id=p.principal_id
        WHERE b.provider=:provider AND b.provider_subject=:subject
          AND m.workspace_id=:workspace
          AND b.status='active' AND m.status='active'
        LIMIT 1
    """), {
        "provider": provider,
        "subject": subject,
        "workspace": workspace_id,
    }).mappings().first()

    if not row:
        raise AuthzError("Workspace authorization denied.")
    return dict(row)


def _completion_percent(
    profile: dict[str, Any],
    member: dict[str, Any],
    claims: dict[str, Any] | None = None,
) -> int:
    email_is_verified = bool((claims or {}).get("email_verified"))
    checks = [
        bool(str(profile.get("full_name") or "").strip()),
        bool(str(member.get("employee_id") or "").strip()),
        bool(str(profile.get("email") or "").strip())
        and profile.get("email_verified_at") is not None
        and email_is_verified,
        bool(str(profile.get("phone_e164") or "").strip()),
        bool(str(profile.get("address_line1") or "").strip()),
        bool(str(profile.get("state") or "").strip()),
        bool(str(profile.get("country") or "").strip()),
        bool(str(profile.get("postal_code") or "").strip()),
        bool(str(profile.get("id_proof_type") or "").strip()),
        bool(str(profile.get("id_proof_number") or "").strip()),
    ]
    return int(sum(checks) * 10)


def _mask(value: Any) -> str:
    compact = str(value or "").replace(" ", "")
    if not compact:
        return ""
    if len(compact) <= 4:
        return "X" * len(compact)
    return ("X" * (len(compact) - 4)) + compact[-4:]


def _safe(
    profile: dict[str, Any] | None,
    member: dict[str, Any],
    claims: dict[str, Any],
) -> dict[str, Any]:
    profile = profile or {}
    phone_verified = profile.get("phone_verified_at") is not None
    return {
        "organization_id": member["organization_id"],
        "workspace_id": member["workspace_id"],
        "principal_id": member["principal_id"],
        "employee_id": member["employee_id"],
        "full_name": profile.get("full_name") or "",
        "email": str(
            claims.get("email") or profile.get("email") or ""
        ).strip().lower(),
        "email_verified": bool(claims.get("email_verified"))
        and profile.get("email_verified_at") is not None,
        "phone_e164": profile.get("phone_e164") or "",
        "phone_verified": phone_verified,
        "address_line1": profile.get("address_line1") or "",
        "address_line2": profile.get("address_line2") or "",
        "state": profile.get("state") or "",
        "state_code": profile.get("state_code") or "",
        "country": profile.get("country") or "",
        "country_code": profile.get("country_code") or "",
        "postal_code": profile.get("postal_code") or "",
        "id_proof_type": profile.get("id_proof_type") or "",
        "id_proof_number_masked": _mask(profile.get("id_proof_number")),
        "profile_completeness_percent": _completion_percent(profile, member, claims),
    }


def get_my_profile(
    claims: dict[str, Any],
    workspace_id: str,
) -> dict[str, Any]:
    with SessionLocal() as db:
        member = _member(db, claims, workspace_id)
        profile = db.execute(text("""
            SELECT full_name, email, email_verified_at, phone_e164, phone_verified_at,
                   address_line1, address_line2, state, state_code, country, country_code,
                   postal_code, id_proof_type, id_proof_number, created_at, updated_at
            FROM organization_member_profiles
            WHERE organization_id=:org AND principal_id=:principal
        """), {
            "org": member["organization_id"],
            "principal": member["principal_id"],
        }).mappings().first()

        result = _safe(dict(profile) if profile else None, member, claims)
        result["profile_exists"] = profile is not None
        result["created_at"] = profile["created_at"] if profile else None
        result["updated_at"] = profile["updated_at"] if profile else None
        return result


def upsert_my_profile(
    claims: dict[str, Any],
    workspace_id: str,
    *,
    full_name: str,
    phone: str,
    phone_country_calling_code: str | None,
    phone_national_number: str | None,
    address_line1: str,
    address_line2: str,
    country_code: str,
    country: str,
    state_code: str,
    state: str,
    postal_code: str,
    id_proof_type: str,
    id_proof_number: str,
) -> dict[str, Any]:
    if not claims.get("email_verified"):
        raise AuthzError("Verified email is required before completing your profile.")

    # Phone is profile data only. Validate/normalize the submitted number and
    # leave phone_verified_at NULL unless a separate authoritative verification has occurred.
    try:
        fields = validate_profile_fields(
            full_name=full_name,
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
    except ValueError as exc:
        raise AuthzError(str(exc)) from exc

    email = str(claims.get("email") or "").strip().lower()
    if not email:
        raise AuthzError("An authenticated email address is required.")
    email_time = _auth_time(claims.get("email_confirmed_at")) or datetime.now(
        timezone.utc
    )

    try:
        with SessionLocal.begin() as db:
            member = _member(db, claims, workspace_id)
            existing = db.execute(text("""
                SELECT phone_e164, phone_verified_at
                FROM organization_member_profiles
                WHERE organization_id=:org AND principal_id=:principal
            """), {
                "org": member["organization_id"],
                "principal": member["principal_id"],
            }).mappings().first()
            exists = existing is not None
            normalized_proof = normalize_id_proof_number(fields["id_proof_number"])
            lock_key = ":".join((
                str(member["organization_id"]),
                fields["country_code"],
                fields["id_proof_type"],
                normalized_proof,
            ))
            # Serialize simultaneous requests for the same proof even before
            # the database trigger migration is installed.
            db.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:lock_key, 0))"),
                {"lock_key": lock_key},
            )
            duplicate = db.execute(text("""
                SELECT 1
                FROM organization_member_profiles
                WHERE organization_id=:org
                  AND principal_id<>:principal
                  AND upper(regexp_replace(id_proof_number, '[[:space:]-]', '', 'g'))=:proof
                  AND id_proof_type=:proof_type
                  AND country_code=:country_code
                LIMIT 1
            """), {
                "org": member["organization_id"],
                "principal": member["principal_id"],
                "proof": normalized_proof,
                "proof_type": fields["id_proof_type"],
                "country_code": fields["country_code"],
            }).first()
            if duplicate:
                raise AuthzError(
                    "This ID proof is already registered to another user in this organization. "
                    "Check the document type and number."
                )
            existing_phone_verified_at = (
                existing["phone_verified_at"]
                if existing and existing["phone_e164"] == fields["phone_e164"]
                else None
            )
    
            db.execute(text("""
                INSERT INTO organization_member_profiles
                  (organization_id, principal_id, full_name, email, email_verified_at,
                   phone_e164, phone_verified_at, address_line1, address_line2,
                   state, state_code, postal_code, country, country_code,
                   id_proof_type, id_proof_number, id_proof_provided_at,
                   created_at, updated_at)
                VALUES
                  (:org, :principal, :full_name, :email, :email_verified_at,
                   :phone, :phone_verified_at, :address_line1, :address_line2,
                   :state, :state_code, :postal_code, :country, :country_code,
                   :id_proof_type, :id_proof_number, now(),
                   coalesce(
                     (SELECT created_at
                      FROM organization_member_profiles
                      WHERE organization_id=:org AND principal_id=:principal),
                     now()),
                   now())
                ON CONFLICT (organization_id, principal_id)
                DO UPDATE SET
                  full_name=EXCLUDED.full_name,
                  email=EXCLUDED.email,
                  email_verified_at=EXCLUDED.email_verified_at,
                  phone_e164=EXCLUDED.phone_e164,
                  phone_verified_at=EXCLUDED.phone_verified_at,
                  address_line1=EXCLUDED.address_line1,
                  address_line2=EXCLUDED.address_line2,
                  state=EXCLUDED.state,
                  state_code=EXCLUDED.state_code,
                  postal_code=EXCLUDED.postal_code,
                  country=EXCLUDED.country,
                  country_code=EXCLUDED.country_code,
                  id_proof_type=EXCLUDED.id_proof_type,
                  id_proof_number=EXCLUDED.id_proof_number,
                  id_proof_provided_at=EXCLUDED.id_proof_provided_at,
                  updated_at=now()
            """), {
                "org": member["organization_id"],
                "principal": member["principal_id"],
                "full_name": fields["full_name"],
                "email": email,
                "email_verified_at": email_time,
                "phone": fields["phone_e164"],
                "phone_verified_at": existing_phone_verified_at,
                "address_line1": fields["address_line1"],
                "address_line2": fields["address_line2"],
                "state": fields["state"],
                "state_code": fields["state_code"],
                "postal_code": fields["postal_code"],
                "country": fields["country"],
                "country_code": fields["country_code"],
                "id_proof_type": fields["id_proof_type"],
                "id_proof_number": fields["id_proof_number"],
            })
    
            db.execute(text("""
                INSERT INTO audit_events
                  (event_id, organization_id, actor_principal_id, action, outcome, metadata)
                VALUES (:event, :org, :actor, :action, 'succeeded', CAST(:metadata AS jsonb))
            """), {
                "event": "evt_" + uuid.uuid4().hex,
                "org": member["organization_id"],
                "actor": member["principal_id"],
                "action": (
                    "people.profile.updated"
                    if exists
                    else "people.profile.created"
                ),
                "metadata": json.dumps({
                    "principal_id": member["principal_id"],
                    "employee_id": member["employee_id"],
                }),
            })
    except IntegrityError as exc:
        # The database trigger is the final guard against concurrent submissions.
        message = str(getattr(getattr(exc, "orig", None), "args", [""])[0]).lower()
        if "duplicate employee id proof" in message:
            raise AuthzError(
                "This ID proof is already registered to another user in this organization."
            ) from exc
        raise

    return get_my_profile(claims, workspace_id)
