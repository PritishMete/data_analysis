import os
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import text

from core.db import SessionLocal

pytestmark = pytest.mark.skipif(
    not os.environ.get("DATABASE_URL"),
    reason="Supabase DATABASE_URL is required",
)


def _claims(uid: str, *, phone_confirmed: bool = True) -> dict:
    return {
        "uid": uid,
        "sub": uid,
        "email": f"{uid}@example.com",
        "email_verified": True,
        "email_confirmed_at": "2026-10-01T00:00:00Z",
        "phone": "+919876543210",
        "phone_confirmed_at": (
            "2026-10-01T00:00:00Z" if phone_confirmed else None
        ),
        "provider": "supabase",
    }


def _profile_kwargs() -> dict:
    return {
        "full_name": "Pritish Mete",
        "phone": "+919876543210",
        "address_line1": "1 InsightFlow Way",
        "address_line2": "Floor 2",
        "state": "West Bengal",
        "state_code": "IN-WB",
        "postal_code": "700001",
        "country": "India",
        "country_code": "IN",
        "id_proof_type": "passport",
        "id_proof_number": "P-1234567",
        "phone_country_calling_code": "+91",
        "phone_national_number": "9876543210",
    }


def _seed_registered(uid: str) -> dict:
    from firebase_authz.supabase_provider import register_organization

    suffix = uuid.uuid4().hex
    return register_organization(
        _claims(uid),
        "Profile Test Company",
        "Main Branch",
        f"PROFILE-{suffix}",
        **_profile_kwargs(),
    )


def _add_member(session, organization_id: str, uid: str, employee_id: str) -> str:
    principal_id = f"prn_profile_{uuid.uuid4().hex}"
    session.execute(
        text("INSERT INTO principals(principal_id) VALUES (:id)"),
        {"id": principal_id},
    )
    session.execute(
        text("""INSERT INTO identity_bindings
                 (provider, provider_subject, firebase_uid, principal_id)
                 VALUES ('supabase', :uid, :uid, :principal)"""),
        {"uid": uid, "principal": principal_id},
    )
    session.execute(
        text("""INSERT INTO organization_members
                 (organization_id, workspace_id, principal_id, employee_id, status)
                 VALUES (:org, :org, :principal, :employee, 'active')"""),
        {
            "org": organization_id,
            "principal": principal_id,
            "employee": employee_id,
        },
    )
    return principal_id


def _cleanup(*organization_ids: str) -> None:
    with SessionLocal.begin() as session:
        for organization_id in organization_ids:
            session.execute(
                text("DELETE FROM organizations WHERE organization_id=:org"),
                {"org": organization_id},
            )


def test_registration_persists_branch_head_profile_and_assignment():
    from firebase_authz.management_domain import list_assignments, management_overview

    suffix = uuid.uuid4().hex
    result = _seed_registered(f"founder-{suffix}")
    try:
        with SessionLocal() as session:
            profile = session.execute(
                text("""SELECT full_name, email, email_verified_at, phone_e164,
                               phone_verified_at, address_line1, address_line2,
                               state, state_code, postal_code, country, country_code,
                               id_proof_type, id_proof_number
                        FROM organization_member_profiles
                        WHERE organization_id=:org"""),
                {"org": result["organization_id"]},
            ).mappings().one()
        assert profile["full_name"] == "Pritish Mete"
        assert profile["email"] == f"founder-{suffix}@example.com"
        assert profile["email_verified_at"] is not None
        assert profile["phone_e164"] == "+919876543210"
        assert profile["phone_verified_at"] is not None
        assert profile["address_line1"] == "1 InsightFlow Way"
        assert profile["id_proof_type"] == "passport"
        assert profile["id_proof_number"] == "P-1234567"

        overview = management_overview(
            _claims(f"founder-{suffix}"),
            result["workspace_id"],
        )
        location = overview["locations"][0]
        assert location["branch_head"]["employee_id"] == "EMP001"
        assert location["branch_head"]["full_name"] == "Pritish Mete"
        assert location["manager"] is None

        assignments = list_assignments(
            _claims(f"founder-{suffix}"),
            result["workspace_id"],
        )
        branch_heads = [a for a in assignments if a["role_id"] == "branch_head"]
        assert len(branch_heads) == 1
        assert branch_heads[0]["employee_id"] == "EMP001"
        assert branch_heads[0]["full_name"] == "Pritish Mete"
        assert branch_heads[0]["email_verified"] is True
        assert branch_heads[0]["phone_verified"] is True
        assert branch_heads[0]["section_name"] is None
        assert branch_heads[0]["reports_to_employee_id"] is None

        safe_fields = set(branch_heads[0])
        assert "email" not in safe_fields
        assert "phone_e164" not in safe_fields
        assert "address_line1" not in safe_fields
        assert "id_proof_number" not in safe_fields
    finally:
        _cleanup(result["organization_id"])


def test_registration_rejects_unverified_phone_authoritatively():
    from firebase_authz.service import AuthzError
    from firebase_authz.supabase_provider import register_organization

    with pytest.raises(AuthzError, match="verified phone"):
        register_organization(
            _claims("unverified-phone", phone_confirmed=False),
            "No Phone Company",
            "Main Branch",
            "NO-PHONE",
            **_profile_kwargs(),
        )


def test_profile_update_rejects_mismatched_verified_phone():
    from firebase_authz.profile_domain import upsert_my_profile
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner = _seed_registered(f"mismatch-owner-{suffix}")
    try:
        claims = _claims(f"mismatch-owner-{suffix}")
        claims["phone"] = "+919999999999"
        with pytest.raises(AuthzError, match="match the verified Supabase phone"):
            upsert_my_profile(
                claims,
                owner["workspace_id"],
                full_name="Pritish Mete",
                phone="+919876543210",
                phone_country_calling_code="+91",
                phone_national_number="9876543210",
                address_line1="1 InsightFlow Way",
                address_line2="",
                country_code="IN",
                country="India",
                state_code="IN-WB",
                state="West Bengal",
                postal_code="700001",
                id_proof_type="passport",
                id_proof_number="P-1234567",
            )
    finally:
        _cleanup(owner["organization_id"])


def test_branch_head_and_manager_are_distinct_roles():
    from firebase_authz.management_domain import assign_manager, management_overview

    suffix = uuid.uuid4().hex
    owner = _seed_registered(f"branch-head-{suffix}")
    try:
        with SessionLocal.begin() as session:
            manager_principal = _add_member(
                session,
                owner["organization_id"],
                f"manager-{suffix}",
                "EMP002",
            )

        manager = assign_manager(
            _claims(f"branch-head-{suffix}"),
            owner["workspace_id"],
            owner["location_id"],
            manager_principal,
        )
        assert manager["role_id"] == "manager"

        location = management_overview(
            _claims(f"branch-head-{suffix}"),
            owner["workspace_id"],
        )["locations"][0]
        assert location["branch_head"]["employee_id"] == "EMP001"
        assert location["manager"]["employee_id"] == "EMP002"
    finally:
        _cleanup(owner["organization_id"])


def test_sensitive_profile_requires_users_manage_and_is_cross_company_scoped():
    from firebase_authz.management_domain import get_assignment_profile
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner = _seed_registered(f"owner-a-{suffix}")
    other = _seed_registered(f"owner-b-{suffix}")
    try:
        with SessionLocal.begin() as session:
            member = _add_member(
                session,
                owner["organization_id"],
                f"member-a-{suffix}",
                "EMP003",
            )
            assignment_id = f"asg_profile_{suffix}"
            session.execute(
                text("""INSERT INTO organizational_assignments
                    (assignment_id, organization_id, principal_id, location_id,
                     role_id, section_id, reports_to_assignment_id, status)
                    VALUES (:assignment, :org, :principal, :location,
                            'employee', NULL, NULL, 'active')"""),
                {
                    "assignment": assignment_id,
                    "org": owner["organization_id"],
                    "principal": member,
                    "location": owner["location_id"],
                },
            )
            session.execute(
                text("""INSERT INTO organization_member_profiles
                    (organization_id, principal_id, full_name, email, phone_e164,
                     id_proof_type, id_proof_number)
                    VALUES (:org, :principal, 'Private Person',
                            'private@example.com', '+15557654321',
                            'Passport', 'SECRET-ID')"""),
                {
                    "org": owner["organization_id"],
                    "principal": member,
                },
            )

        profile = get_assignment_profile(
            _claims(f"owner-a-{suffix}"),
            owner["workspace_id"],
            assignment_id,
        )
        assert profile["email"] == "private@example.com"
        assert profile["id_proof_number"] == "SECRET-ID"

        with pytest.raises(AuthzError, match="sensitive employee profile"):
            get_assignment_profile(
                {
                    **_claims(f"member-a-{suffix}"),
                },
                owner["workspace_id"],
                assignment_id,
            )

        with pytest.raises(AuthzError):
            get_assignment_profile(
                _claims(f"owner-b-{suffix}"),
                other["workspace_id"],
                assignment_id,
            )
    finally:
        _cleanup(owner["organization_id"], other["organization_id"])


def test_profile_safe_response_masks_short_id_proof():
    from firebase_authz.profile_domain import _mask

    assert _mask("12") == "XX"
    assert _mask("1234") == "XXXX"
    assert _mask("12345") == "X2345"


def test_profile_is_removed_when_member_is_deleted():
    suffix = uuid.uuid4().hex
    owner = _seed_registered(f"cleanup-owner-{suffix}")
    try:
        with SessionLocal.begin() as session:
            before = session.execute(
                text("""SELECT count(*) FROM organization_member_profiles
                        WHERE organization_id=:org"""),
                {"org": owner["organization_id"]},
            ).scalar_one()
            assert before == 1
            session.execute(
                text("""DELETE FROM organization_members
                        WHERE organization_id=:org"""),
                {"org": owner["organization_id"]},
            )
            after = session.execute(
                text("""SELECT count(*) FROM organization_member_profiles
                        WHERE organization_id=:org"""),
                {"org": owner["organization_id"]},
            ).scalar_one()
        assert after == 0
    finally:
        _cleanup(owner["organization_id"])


def test_profile_migration_has_rls_and_no_public_data_api_grants():
    migration = open(
        "migrations/0019_organization_member_profiles.sql",
        encoding="utf-8",
    ).read()
    assert "ALTER TABLE organization_member_profiles ENABLE ROW LEVEL SECURITY" in migration
    assert "REVOKE ALL ON TABLE organization_member_profiles FROM PUBLIC" in migration
    assert "REFERENCES organization_members (organization_id, principal_id)" in migration
    assert "ON DELETE CASCADE" in migration

    additive = open(
        "migrations/0020_add_profile_geo_codes.sql",
        encoding="utf-8",
    ).read()
    assert "ADD COLUMN IF NOT EXISTS country_code TEXT" in additive
    assert "ADD COLUMN IF NOT EXISTS state_code TEXT" in additive
    assert "idx_member_profiles_org_country_state" in additive
