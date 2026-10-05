import os
import uuid

import pytest
from sqlalchemy import text

from core.db import SessionLocal

pytestmark = pytest.mark.skipif(
    not os.environ.get("DATABASE_URL"), reason="Supabase DATABASE_URL is required"
)


def _claims(uid: str) -> dict:
    return {
        "uid": uid,
        "sub": uid,
        "email": f"{uid}@example.com",
        "email_verified": True,
        "email_confirmed_at": "2026-10-01T00:00:00Z",
        "phone": "+919876543210",
        "phone_confirmed_at": "2026-10-01T00:00:00Z",
        "firebase": {
            "sign_in_provider": "password",
            "identities": {"password": [uid]},
        },
    }


def _add_member(session, organization_id: str, uid: str, employee_id: str, role: str = "employee") -> str:
    principal_id = f"prn_test_{uuid.uuid4().hex}"
    session.execute(
        text("INSERT INTO principals(principal_id) VALUES (:id)"),
        {"id": principal_id},
    )
    session.execute(
        text("""INSERT INTO identity_bindings(provider, provider_subject, firebase_uid, principal_id)
                VALUES ('firebase', :uid, :uid, :principal)"""),
        {"uid": uid, "principal": principal_id},
    )
    session.execute(
        text("""INSERT INTO organization_members
                (organization_id, workspace_id, principal_id, employee_id, status)
                VALUES (:org, :org, :principal, :employee, 'active')"""),
        {"org": organization_id, "principal": principal_id, "employee": employee_id},
    )
    session.execute(
        text("""INSERT INTO member_roles(organization_id, principal_id, role_id)
                VALUES (:org, :principal, :role)"""),
        {"org": organization_id, "principal": principal_id, "role": role},
    )
    return principal_id


def _seed_org(owner_uid: str, name: str, branch_id: str) -> dict:
    from firebase_authz.supabase_provider import register_organization
    suffix = str(uuid.uuid4().int)[:8]
    return register_organization(
        _claims(owner_uid),
        name,
        "Main Branch",
        branch_id,
        full_name=f"Owner {owner_uid}",
        phone="+919876543210",
        address_line1="1 InsightFlow Way",
        state="California",
        state_code="US-CA",
        postal_code="90210",
        country="United States",
        country_code="US",
        phone_country_calling_code="+91",
        phone_national_number="9876543210",
        id_proof_type="passport",
        id_proof_number="TEST-" + suffix,
    )


def _cleanup(*organization_ids: str) -> None:
    from core.db import SessionLocal
    with SessionLocal.begin() as session:
        for organization_id in organization_ids:
            session.execute(
                text("DELETE FROM organizations WHERE organization_id=:org"),
                {"org": organization_id},
            )


def test_management_reads_are_organization_scoped():
    from firebase_authz.management_domain import (
        create_location,
        list_assignments,
        list_locations,
        list_people,
        list_sections,
        management_overview,
    )
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    a = _seed_org(f"management-owner-a-{suffix}", "Management A", f"MGMT-A-{suffix}")
    b = _seed_org(f"management-owner-b-{suffix}", "Management B", f"MGMT-B-{suffix}")
    try:
        with SessionLocal.begin() as session:
            _add_member(session, a["organization_id"], f"a-employee-{suffix}", "EMP-A")
            _add_member(session, b["organization_id"], f"b-employee-{suffix}", "EMP-B")

        overview = management_overview(_claims(f"management-owner-a-{suffix}"), a["workspace_id"])
        assert overview["organization"]["organization_id"] == a["organization_id"]
        assert all(item["organization_id"] == a["organization_id"] for item in overview["locations"])

        assert all(
            item["organization_id"] == a["organization_id"]
            for item in list_locations(_claims(f"management-owner-a-{suffix}"), a["workspace_id"])
        )
        assert all(
            item["organization_id"] == a["organization_id"]
            for item in list_sections(_claims(f"management-owner-a-{suffix}"), a["workspace_id"])
        )
        assert all(
            item["organization_id"] == a["organization_id"]
            for item in list_people(_claims(f"management-owner-a-{suffix}"), a["workspace_id"])
        )
        assert all(
            item["organization_id"] == a["organization_id"]
            for item in list_assignments(_claims(f"management-owner-a-{suffix}"), a["workspace_id"])
        )

        with pytest.raises(AuthzError):
            management_overview(_claims(f"management-owner-a-{suffix}"), b["workspace_id"])
        with pytest.raises(AuthzError):
            list_locations(_claims(f"management-owner-a-{suffix}"), b["workspace_id"])
    finally:
        _cleanup(a["organization_id"], b["organization_id"])



def test_branch_head_population_is_branch_scoped_and_all_scope_binds_are_supplied():
    from firebase_authz.management_domain import (
        list_assignments,
        list_locations,
        list_people,
        list_sections,
        management_overview,
    )

    suffix = uuid.uuid4().hex
    owner_uid = f"branch-head-scope-{suffix}"
    branch_employee_uid = f"branch-employee-{suffix}"
    other_employee_uid = f"other-employee-{suffix}"
    org = _seed_org(owner_uid, "Branch Head Scope", f"BRANCH-SCOPE-{suffix}")
    try:
        owner = _claims(owner_uid)
        with SessionLocal.begin() as session:
            branch_employee = _add_member(
                session, org["organization_id"], branch_employee_uid, "EMP-BRANCH"
            )
            other_employee = _add_member(
                session, org["organization_id"], other_employee_uid, "EMP-OTHER"
            )
        second = create_location(
            owner,
            org["workspace_id"],
            "Other Branch",
            f"OTHER-{suffix}",
        )

        with SessionLocal.begin() as session:
            session.execute(
                text("""
                    INSERT INTO organizational_assignments
                      (assignment_id, organization_id, principal_id, location_id, role_id, status)
                    VALUES (:assignment, :org, :principal, :location, 'employee', 'active')
                """),
                {
                    "assignment": f"asg_branch_{uuid.uuid4().hex}",
                    "org": org["organization_id"],
                    "principal": branch_employee,
                    "location": org["location_id"],
                },
            )
            session.execute(
                text("""
                    INSERT INTO organizational_assignments
                      (assignment_id, organization_id, principal_id, location_id, role_id, status)
                    VALUES (:assignment, :org, :principal, :location, 'employee', 'active')
                """),
                {
                    "assignment": f"asg_other_{uuid.uuid4().hex}",
                    "org": org["organization_id"],
                    "principal": other_employee,
                    "location": second["location_id"],
                },
            )

        overview = management_overview(owner, org["workspace_id"])
        assert overview["locations"][0]["employee_count"] == 1
        assert overview["locations"][0]["location_id"] == org["location_id"]
        assert overview["actor"]["role_id"] == "branch_head"
        assert overview["actor"]["location_id"] == org["location_id"]
        assert overview["summary"]["location_count"] == 1
        assert overview["summary"]["total_people"] == 2
        assert overview["summary"]["branch_head_count"] == 1
        assert overview["summary"]["employee_count"] == 1
        assert {item["location_id"] for item in overview["locations"]} == {org["location_id"]}

        locations = list_locations(owner, org["workspace_id"])
        assert [item["location_id"] for item in locations] == [org["location_id"]]

        sections = list_sections(owner, org["workspace_id"])
        assert all(item["location_id"] == org["location_id"] for item in sections)

        people = list_people(owner, org["workspace_id"])
        assert people
        assert all(item["organization_id"] == org["organization_id"] for item in people)
        assert all(item["location_id"] == org["location_id"] for item in people)
        assert {item["employee_id"] for item in people} == {
            org["employee_id"],
            "EMP-BRANCH",
        }

        assignments = list_assignments(owner, org["workspace_id"])
        assert assignments
        assert all(item["organization_id"] == org["organization_id"] for item in assignments)
        assert all(item["location_id"] == org["location_id"] for item in assignments)
        assert {item["employee_id"] for item in assignments} == {
            org["employee_id"],
            "EMP-BRANCH",
        }
    finally:
        _cleanup(org["organization_id"])


def test_invitation_visibility_is_recipient_private_and_branch_head_scoped():
    from firebase_authz.supabase_provider import management_snapshot

    suffix = uuid.uuid4().hex
    owner_uid = f"invite-owner-{suffix}"
    branch_head_uid = f"invite-branch-head-{suffix}"
    employee_uid = f"invite-recipient-{suffix}"
    other_recipient_uid = f"invite-other-recipient-{suffix}"
    org = _seed_org(owner_uid, "Invitation Visibility", f"INV-VIS-{suffix}")
    try:
        with SessionLocal.begin() as session:
            branch_head = _add_member(
                session, org["organization_id"], branch_head_uid, "BH-VIS", role="branch_head"
            )
            employee = _add_member(
                session, org["organization_id"], employee_uid, "EMP-VIS", role="employee"
            )
            _add_member(
                session, org["organization_id"], other_recipient_uid, "EMP-OTHER-VIS", role="employee"
            )
            session.execute(
                text("""
                    INSERT INTO organizational_assignments
                      (assignment_id, organization_id, principal_id, location_id, role_id, status)
                    VALUES (:assignment, :org, :principal, :location, 'branch_head', 'active')
                """),
                {
                    "assignment": f"asg_bh_{uuid.uuid4().hex}",
                    "org": org["organization_id"],
                    "principal": branch_head,
                    "location": org["location_id"],
                },
            )
            second = session.execute(
                text("""
                    INSERT INTO locations(location_id, organization_id, name, branch_identifier)
                    VALUES (:location, :org, 'Other Branch', :identifier)
                    RETURNING location_id
                """),
                {
                    "location": f"loc_{uuid.uuid4().hex}",
                    "org": org["organization_id"],
                    "identifier": f"OTHER-{suffix}",
                },
            ).scalar_one()

            owner_principal = session.execute(
                text("""
                    SELECT principal_id FROM identity_bindings
                    WHERE provider='firebase' AND provider_subject=:uid
                """),
                {"uid": owner_uid},
            ).scalar_one()
            session.execute(
                text("""
                    INSERT INTO invitations
                      (invitation_id, organization_id, email, role_id, status,
                       created_by_principal_id, location_id)
                    VALUES
                      (:main_id, :org, :main_email, 'employee', 'invited', :creator, :main_location),
                      (:other_id, :org, :other_email, 'manager', 'invited', :creator, :other_location),
                      (:recipient_id, :org, :recipient_email, 'employee', 'invited', :creator, :other_location)
                """),
                {
                    "main_id": f"inv_{uuid.uuid4().hex}",
                    "other_id": f"inv_{uuid.uuid4().hex}",
                    "recipient_id": f"inv_{uuid.uuid4().hex}",
                    "org": org["organization_id"],
                    "main_email": f"branch-recipient-{suffix}@example.com",
                    "other_email": f"other-branch-{suffix}@example.com",
                    "recipient_email": f"{employee_uid}@example.com",
                    "creator": owner_principal,
                    "main_location": org["location_id"],
                    "other_location": second,
                },
            )

        branch_head_result = management_snapshot(
            _claims(branch_head_uid), org["workspace_id"]
        )
        branch_head_invitations = branch_head_result["invitations"]
        assert len(branch_head_invitations) == 1
        assert branch_head_invitations[0]["location_id"] == org["location_id"]
        assert branch_head_invitations[0]["sender_name"] == f"Owner {owner_uid}"
        assert branch_head_invitations[0]["sender_role_id"] == "branch_head"
        assert branch_head_invitations[0]["recipient_display"] == f"branch-recipient-{suffix}@example.com"

        employee_result = management_snapshot(
            _claims(employee_uid), org["workspace_id"]
        )
        employee_invitations = employee_result["invitations"]
        assert len(employee_invitations) == 1
        assert employee_invitations[0]["email"] == f"{employee_uid}@example.com"
        assert employee_invitations[0]["location_id"] == second
        assert employee_invitations[0]["email"] != f"branch-recipient-{suffix}@example.com"
    finally:
        _cleanup(org["organization_id"])


def test_manager_assignment_conflict_replacement_and_audit_are_atomic():
    from firebase_authz.management_domain import assign_manager, replace_manager, list_audit_events
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner_uid = f"manager-owner-{suffix}"
    manager_one_uid = f"manager-one-{suffix}"
    manager_two_uid = f"manager-two-{suffix}"
    org = _seed_org(owner_uid, "Manager Assignment", f"MANAGER-{suffix}")
    try:
        with SessionLocal.begin() as session:
            manager_one = _add_member(session, org["organization_id"], manager_one_uid, "MGR-1")
            manager_two = _add_member(session, org["organization_id"], manager_two_uid, "MGR-2")

        owner = _claims(owner_uid)
        first = assign_manager(owner, org["workspace_id"], org["location_id"], manager_one)
        assert first["role_id"] == "manager"
        assert first["status"] == "active"

        with pytest.raises(AuthzError, match="already has an active manager"):
            assign_manager(owner, org["workspace_id"], org["location_id"], manager_two)

        replacement = replace_manager(owner, org["workspace_id"], org["location_id"], manager_two)
        assert replacement["principal_id"] == manager_two
        assert replacement["status"] == "active"

        with SessionLocal() as session:
            rows = session.execute(
                text("""SELECT principal_id, status FROM organizational_assignments
                        WHERE organization_id=:org AND location_id=:location
                          AND role_id='manager' ORDER BY created_at"""),
                {"org": org["organization_id"], "location": org["location_id"]},
            ).all()
            audit = session.execute(
                text("""SELECT action, outcome, metadata FROM audit_events
                        WHERE organization_id=:org AND action LIKE 'management.manager.%'
                        ORDER BY created_at"""),
                {"org": org["organization_id"]},
            ).all()

        assert rows[-1].principal_id == manager_two
        assert rows[-1].status == "active"
        assert any(row.status == "inactive" and row.principal_id == manager_one for row in rows)
        assert [row.action for row in audit] == [
            "management.manager.assigned",
            "management.manager.changed",
        ]
        assert all(row.outcome == "succeeded" for row in audit)
    finally:
        _cleanup(org["organization_id"])


def test_manager_scope_and_team_lead_reporting_relationships():
    from firebase_authz.management_domain import (
        assign_manager,
        assign_team_lead,
        create_location,
        create_section,
        set_reporting_relationship,
    )
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner_uid = f"scope-owner-{suffix}"
    manager_uid = f"scope-manager-{suffix}"
    lead_uid = f"scope-lead-{suffix}"
    employee_uid = f"scope-employee-{suffix}"
    org = _seed_org(owner_uid, "Scope Management", f"SCOPE-MGMT-{suffix}")
    try:
        owner = _claims(owner_uid)
        with SessionLocal.begin() as session:
            manager = _add_member(session, org["organization_id"], manager_uid, "MGR-SCOPE")
            lead = _add_member(session, org["organization_id"], lead_uid, "LEAD-SCOPE")
            employee = _add_member(session, org["organization_id"], employee_uid, "EMP-SCOPE")

        second_location = create_location(owner, org["workspace_id"], "North Branch", f"NORTH-{suffix}")
        manager_assignment = assign_manager(owner, org["workspace_id"], org["location_id"], manager)
        main_section = create_section(owner, org["workspace_id"], org["location_id"], "Sales")

        manager_claims = _claims(manager_uid)
        manager_section = create_section(
            manager_claims, org["workspace_id"], org["location_id"], "Finance"
        )
        assert manager_section["location_id"] == org["location_id"]

        with pytest.raises(AuthzError):
            create_section(manager_claims, org["workspace_id"], second_location["location_id"], "North Sales")

        lead_assignment = assign_team_lead(
            owner,
            org["workspace_id"],
            org["location_id"],
            main_section["section_id"],
            lead,
            manager_assignment["assignment_id"],
        )

        with pytest.raises(AuthzError):
            assign_manager(
                _claims(lead_uid), org["workspace_id"], org["location_id"], lead
            )
        assert lead_assignment["reports_to_assignment_id"] == manager_assignment["assignment_id"]

        with pytest.raises(AuthzError, match="same location"):
            assign_team_lead(
                owner,
                org["workspace_id"],
                second_location["location_id"],
                main_section["section_id"],
                lead,
                manager_assignment["assignment_id"],
            )

        with SessionLocal.begin() as session:
            employee_assignment_id = f"asg_test_{uuid.uuid4().hex}"
            session.execute(
                text("""INSERT INTO organizational_assignments
                        (assignment_id, organization_id, principal_id, location_id, role_id, section_id, status)
                        VALUES (:assignment, :org, :principal, :location, 'employee', :section, 'active')"""),
                {
                    "assignment": employee_assignment_id,
                    "org": org["organization_id"],
                    "principal": employee,
                    "location": org["location_id"],
                    "section": main_section["section_id"],
                },
            )

        employee_assignment = set_reporting_relationship(
            owner,
            org["workspace_id"],
            employee_assignment_id,
            lead_assignment["assignment_id"],
        )
        assert employee_assignment["reports_to_assignment_id"] == lead_assignment["assignment_id"]

        with pytest.raises(AuthzError, match="higher organizational role"):
            set_reporting_relationship(
                owner,
                org["workspace_id"],
                manager_assignment["assignment_id"],
                employee_assignment["assignment_id"],
            )

        with pytest.raises(AuthzError, match="itself"):
            set_reporting_relationship(
                owner,
                org["workspace_id"],
                lead_assignment["assignment_id"],
                lead_assignment["assignment_id"],
            )

        with pytest.raises(AuthzError):
            set_reporting_relationship(
                owner,
                org["workspace_id"],
                lead_assignment["assignment_id"],
                "asg_from_other_company",
            )
    finally:
        _cleanup(org["organization_id"])


def test_cross_company_mutations_and_invalid_members_are_rejected():
    from firebase_authz.management_domain import assign_manager, create_section
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner_a_uid = f"cross-owner-a-{suffix}"
    owner_b_uid = f"cross-owner-b-{suffix}"
    candidate_a_uid = f"cross-candidate-a-{suffix}"
    candidate_b_uid = f"cross-candidate-b-{suffix}"
    a = _seed_org(owner_a_uid, "Cross Company A", f"CROSS-A-{suffix}")
    b = _seed_org(owner_b_uid, "Cross Company B", f"CROSS-B-{suffix}")
    try:
        with SessionLocal.begin() as session:
            candidate_a = _add_member(session, a["organization_id"], candidate_a_uid, "EMP-A")
            candidate_b = _add_member(session, b["organization_id"], candidate_b_uid, "EMP-B")

        owner_a = _claims(owner_a_uid)
        with pytest.raises(AuthzError):
            assign_manager(owner_a, a["workspace_id"], a["location_id"], candidate_b)
        with pytest.raises(AuthzError):
            assign_manager(owner_a, b["workspace_id"], b["location_id"], candidate_a)
        with pytest.raises(AuthzError):
            create_section(owner_a, a["workspace_id"], b["location_id"], "Foreign Section")
    finally:
        _cleanup(a["organization_id"], b["organization_id"])


def test_unauthorized_suspended_removed_and_invalid_targets_are_rejected():
    from firebase_authz.management_domain import (
        assign_manager,
        assign_team_lead,
        create_section,
        set_reporting_relationship,
    )
    from firebase_authz.service import AuthzError

    suffix = uuid.uuid4().hex
    owner_uid = f"state-owner-{suffix}"
    employee_uid = f"state-employee-{suffix}"
    lead_uid = f"state-lead-{suffix}"
    org = _seed_org(owner_uid, "State Checks", f"STATE-{suffix}")
    try:
        owner = _claims(owner_uid)
        with SessionLocal.begin() as session:
            employee = _add_member(session, org["organization_id"], employee_uid, "EMP-STATE")
            lead = _add_member(session, org["organization_id"], lead_uid, "LEAD-STATE")

        section = create_section(owner, org["workspace_id"], org["location_id"], "Operations")

        with pytest.raises(AuthzError):
            assign_manager(_claims(employee_uid), org["workspace_id"], org["location_id"], employee)

        assign_manager(owner, org["workspace_id"], org["location_id"], lead)

        with SessionLocal.begin() as session:
            session.execute(
                text("""UPDATE organization_members
                        SET status='suspended'
                        WHERE organization_id=:org AND principal_id=:principal"""),
                {"org": org["organization_id"], "principal": employee},
            )
        with pytest.raises(AuthzError):
            assign_manager(owner, org["workspace_id"], org["location_id"], employee)

        with SessionLocal.begin() as session:
            session.execute(
                text("""UPDATE organization_members
                        SET status='active'
                        WHERE organization_id=:org AND principal_id=:principal"""),
                {"org": org["organization_id"], "principal": employee},
            )
        lead_assignment = assign_team_lead(
            owner, org["workspace_id"], org["location_id"], section["section_id"], lead
        )

        with SessionLocal.begin() as session:
            session.execute(
                text("""UPDATE organizational_assignments
                        SET status='inactive'
                        WHERE assignment_id=:assignment"""),
                {"assignment": lead_assignment["assignment_id"]},
            )
        with pytest.raises(AuthzError):
            set_reporting_relationship(
                owner,
                org["workspace_id"],
                lead_assignment["assignment_id"],
                None,
            )

        with pytest.raises(AuthzError):
            create_section(owner, org["workspace_id"], "missing-location", "Invalid")

        with pytest.raises(AuthzError):
            assign_team_lead(
                owner,
                org["workspace_id"],
                org["location_id"],
                "missing-section",
                employee,
            )

        with SessionLocal.begin() as session:
            session.execute(
                text("""UPDATE organization_members
                        SET status='removed'
                        WHERE organization_id=:org AND principal_id=:principal"""),
                {"org": org["organization_id"], "principal": employee},
            )
        with pytest.raises(AuthzError):
            assign_manager(owner, org["workspace_id"], org["location_id"], employee)
    finally:
        _cleanup(org["organization_id"])
