import hashlib
import os
import threading

import pytest
from sqlalchemy import text


pytestmark = pytest.mark.skipif(
    not os.environ.get("DATABASE_URL"), reason="Supabase DATABASE_URL is required"
)

@pytest.fixture(autouse=True)
def _stub_supabase_auth_admin_for_database_tests(monkeypatch):
    """Keep PostgreSQL authorization tests isolated from real Supabase/email APIs."""
    from firebase_authz import supabase_provider

    def invite_user_by_email(email, redirect_to, *, organization_name):
        local = str(email).strip().lower().split("@", 1)[0]
        # Test identities use their email local-part as their stable Supabase
        # subject. The explicit invitation fixture uses "guest-" for its email
        # and "invite-guest-" for its subject.
        user_id = local
        return {"user_id": user_id, "email_confirmed": False}

    monkeypatch.setattr(supabase_provider, "invite_user_by_email", invite_user_by_email)

_PHONE_LOCK = threading.Lock()
_PHONE_BY_SUBJECT: dict[str, str] = {}


def _phone_for_subject(subject: str) -> str:
    with _PHONE_LOCK:
        if subject not in _PHONE_BY_SUBJECT:
            slot = len(_PHONE_BY_SUBJECT)
            if slot >= 100:
                raise RuntimeError("Test phone-number fixture pool exhausted.")
            _PHONE_BY_SUBJECT[subject] = f"+120255501{slot:02d}"
        return _PHONE_BY_SUBJECT[subject]


def _register_organization(claims, organization_name, branch_name, branch_identifier, **overrides):
    from firebase_authz.supabase_provider import register_organization

    normalized_claims = dict(claims)
    subject = str(normalized_claims.get("sub") or normalized_claims.get("uid") or "")
    normalized_claims["sub"] = subject
    normalized_claims["uid"] = subject
    normalized_claims.setdefault("email", f"{subject}@example.com")
    normalized_claims["email_verified"] = True
    normalized_claims["email_confirmed_at"] = "2026-10-01T00:00:00Z"
    digest = hashlib.sha256(subject.encode("utf-8")).hexdigest().upper()
    phone = _phone_for_subject(subject)
    profile = {
        "full_name": f"Test Owner {digest[:8]}",
        "phone": phone,
        "address_line1": "1 Test Way",
        "state": "California",
        "state_code": "US-CA",
        "postal_code": "90210",
        "country": "United States",
        "country_code": "US",
        "id_proof_type": "passport",
        "id_proof_number": f"TEST{digest[:16]}",
        "phone_country_calling_code": "+1",
        "phone_national_number": phone[2:],
    }
    profile.update(overrides)
    return register_organization(
        normalized_claims, organization_name, branch_name, branch_identifier, **profile
    )


def test_supabase_registration_persists_branch_head_context():
    from firebase_authz.supabase_provider import register_organization
    from core.db import SessionLocal

    claims = {
        "uid": "integration-test-user",
        "sub": "integration-test-user",
    }
    result = _register_organization(claims, "ABC", "Kolkata Branch A", "ABC-KOL-A")
    assert result["organization_id"].startswith("org_")
    assert result["workspace_id"] == result["organization_id"]
    assert result["role_ids"] == ["branch_head"]

    with SessionLocal() as session:
        connection = session.connection()
        row = connection.execute(text("""SELECT o.name, w.workspace_id, m.employee_id, mr.role_id, l.name AS branch_name
            FROM organizations o
            JOIN workspaces w ON w.organization_id = o.organization_id
            JOIN organization_members m ON m.organization_id = o.organization_id
            JOIN member_roles mr ON mr.organization_id = m.organization_id AND mr.principal_id = m.principal_id
            JOIN locations l ON l.organization_id = o.organization_id
            WHERE o.organization_id = :id"""), {"id": result["organization_id"]}).one()
        assignment = connection.execute(text("""SELECT oa.location_id, oa.role_id, oa.status
            FROM organizational_assignments oa
            JOIN identity_bindings ib ON ib.principal_id = oa.principal_id
            WHERE oa.organization_id = :id AND ib.provider = 'supabase' AND ib.provider_subject = :principal"""),
                                        {"id": result["organization_id"], "principal": claims["uid"]}).one()
    assert row.name == "ABC"
    assert row.workspace_id == result["workspace_id"]
    assert row.employee_id == result["employee_id"]
    assert row.employee_id == "EMP001"
    assert row.role_id == "branch_head"
    assert row.branch_name == "Kolkata Branch A"
    assert assignment.location_id == result["location_id"]
    assert assignment.role_id == "branch_head"
    assert assignment.status == "active"

    with SessionLocal.begin() as session:
        session.execute(text("DELETE FROM organizations WHERE organization_id = :id"), {"id": result["organization_id"]})


def test_supabase_registration_rejects_invalid_organization_or_branch_names():
    from firebase_authz.supabase_provider import register_organization

    with pytest.raises(ValueError):
        _register_organization({"uid": "u"}, "bad\nname", "Main Branch", "BAD-01")
    with pytest.raises(ValueError):
        _register_organization({"uid": "u"}, "ABC", "bad\nbranch", "BAD-01")


def test_supabase_registration_allows_special_branch_identifier_characters():
    from firebase_authz.supabase_provider import register_organization
    from core.db import SessionLocal

    identifier = "tcs@singur_1!#$%^&*+=?"
    result = _register_organization(
        {"uid": "special-branch-id-test"},
        "Special Identifier Test",
        "Singur",
        identifier,
    )
    try:
        assert result["branch_identifier"] == identifier
        with SessionLocal() as session:
            stored = session.execute(
                text("SELECT branch_identifier FROM locations WHERE location_id=:id"),
                {"id": result["location_id"]},
            ).scalar_one()
        assert stored == identifier
    finally:
        with SessionLocal.begin() as session:
            session.execute(
                text("DELETE FROM organizations WHERE organization_id=:id"),
                {"id": result["organization_id"]},
            )


def test_supabase_registration_rolls_back_when_final_registration_stage_fails(monkeypatch):
    from firebase_authz.supabase_provider import register_organization
    from core.db import SessionLocal

    def fail_final_stage(name):
        if name == "DB_COMMIT_COMPLETE":
            raise RuntimeError("simulated final registration failure")

    monkeypatch.setattr("firebase_authz.registration_diagnostics.stage", fail_final_stage)

    with pytest.raises(RuntimeError, match="simulated final registration failure"):
        _register_organization(
            {"uid": "registration-rollback-test"},
            "Rollback Test",
            "Rollback Branch",
            "ROLLBACK-TEST",
        )

    with SessionLocal() as session:
        assert session.execute(
            text("SELECT 1 FROM locations WHERE branch_identifier=:id"),
            {"id": "ROLLBACK-TEST"},
        ).scalar_one_or_none() is None
        assert session.execute(
            text("SELECT 1 FROM organizations WHERE name=:name"),
            {"name": "Rollback Test"},
        ).scalar_one_or_none() is None


def test_supabase_registration_rejects_existing_active_membership():
    from firebase_authz.supabase_provider import OrganizationRegistrationConflict, register_organization
    from core.db import SessionLocal

    result = _register_organization(
        {"uid": "duplicate-org-user", "sub": "duplicate-org-user"},
        "Existing Membership",
        "Main Branch",
        "EXISTING-MEMBERSHIP",
    )
    try:
        with pytest.raises(OrganizationRegistrationConflict):
            _register_organization(
                {"uid": "duplicate-org-user", "sub": "duplicate-org-user"},
                "Second Organization",
                "Second Branch",
                "SECOND-ORG",
            )
        with SessionLocal() as session:
            assert session.execute(
                text("SELECT count(*) FROM organizations WHERE name=:name"),
                {"name": "Second Organization"},
            ).scalar_one() == 0
    finally:
        with SessionLocal.begin() as session:
            session.execute(
                text("DELETE FROM organizations WHERE organization_id=:id"),
                {"id": result["organization_id"]},
            )


def test_supabase_registration_rejects_duplicate_active_branch_identifier():
    from firebase_authz.supabase_provider import register_organization
    from firebase_authz.auth import AuthzError
    from core.db import SessionLocal

    first = _register_organization({"uid": "branch-id-one"}, "Branch ID One", "Kolkata A", "UNIQUE-BRANCH-01")
    try:
        with pytest.raises((ValueError, AuthzError)):
            _register_organization({"uid": "branch-id-two"}, "Branch ID Two", "Kolkata B", "UNIQUE-BRANCH-01")
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": first["organization_id"]})


def test_dataset_and_working_copy_authorization_is_workspace_scoped():
    from sqlalchemy import text
    from core.db import SessionLocal
    from firebase_authz.supabase_provider import (
        authorize_dataset,
        authorize_working_copy,
        create_working_copy,
        delete_dataset_authorization,
        register_dataset,
        register_organization,
    )

    claims = {"uid": "dataset-test-user", "sub": "dataset-test-user"}
    result = _register_organization(claims, "Dataset Test", "Main Branch", "DATASET-TEST")
    register_dataset(claims, result["workspace_id"], "ds_test", "dataset-test-user")
    assert authorize_dataset(claims, result["workspace_id"], "ds_test", "dataset.view_original")["authorized"]
    create_working_copy(claims, result["workspace_id"], "ds_test", "wc_test", "1")
    assert authorize_working_copy(claims, result["workspace_id"], "wc_test", "working_copy.modify")["authorized"]

    # Removing the master's ACL must not invalidate the independent copy ACL
    # or its persisted branch scope.
    delete_dataset_authorization(result["workspace_id"], "ds_test")
    assert authorize_working_copy(
        claims, result["workspace_id"], "wc_test", "working_copy.modify"
    )["authorized"]
    from firebase_authz.auth import AuthzError
    with pytest.raises(AuthzError):
        authorize_dataset(claims, "org_other", "ds_test", "dataset.view_original")
    with SessionLocal.begin() as session:
        session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_invitation_acceptance_membership_and_role_are_transactional():
    import uuid
    from firebase_authz.auth import AuthzError
    from firebase_authz.supabase_provider import (
        accept_invitation, create_invitation, mutate_role, pending_invitations,
        register_organization, set_membership_status,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"invite-owner-{suffix}"
    guest_uid = f"guest-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"owner-{suffix}@example.com"}
    guest = {"uid": guest_uid, "sub": guest_uid, "email": f"guest-{suffix}@example.com"}
    result = _register_organization(owner, "Invitation Test", "Main Branch", "INVITATION-TEST")
    workspace = result["workspace_id"]
    try:
        invitation = create_invitation(owner, workspace, guest["email"], "data_analyst")
        pending = pending_invitations(guest)
        assert pending[0]["invitation_id"] == invitation["invitation_id"]
        assert pending[0]["organization_name"] == "Invitation Test"
        accepted = accept_invitation(guest, workspace, invitation["invitation_id"])
        assert accepted["accepted"] is True
        with SessionLocal() as db:
            row = db.execute(text("""SELECT m.status, mr.role_id FROM organization_members m
                JOIN identity_bindings b ON b.principal_id=m.principal_id
                JOIN member_roles mr ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
                    WHERE m.organization_id=:org AND b.provider='supabase' AND b.provider_subject=:uid"""),
                           {"org": workspace, "uid": guest_uid}).one()
        assert row.status == "active"
        assert row.role_id == "data_analyst"
        assert set_membership_status(owner, workspace, guest_uid, "suspended") is True
        with pytest.raises(AuthzError):
            mutate_role(guest, workspace, owner_uid, "manager", True)
        with pytest.raises(AuthzError):
            accept_invitation(guest, "org_wrong", invitation["invitation_id"])
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_invited_member_reports_incomplete_profile_to_auth_gate():
    import uuid
    from firebase_authz.supabase_provider import (
        accept_invitation,
        authorization_context,
        create_invitation,
        register_organization,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"profile-owner-{suffix}"
    guest_uid = f"guest-{suffix}"
    owner = {
        "uid": owner_uid,
        "sub": owner_uid,
        "email": f"owner-{suffix}@example.com",
    }
    guest = {
        "uid": guest_uid,
        "sub": guest_uid,
        "email": f"guest-{suffix}@example.com",
    }
    result = _register_organization(owner, f"Profile Gate {suffix}", "Main", f"PROFILE-GATE-{suffix}")
    workspace = result["workspace_id"]
    try:
        invitation = create_invitation(owner, workspace, guest["email"], "data_analyst")
        accept_invitation(guest, workspace, invitation["invitation_id"])

        context = authorization_context(guest, workspace)
        assert context["membership_status"] == "active"
        assert context["workspace_id"] == workspace
        assert context["employee_id"]
        assert context["role_ids"] == ["data_analyst"]
        assert context["profile_complete"] is False
        assert context["workspaces"][0]["membership_status"] == "active"
        assert context["workspaces"][0]["profile_complete"] is False

        import firebase_authz.routes as routes
        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
        monkeypatch.setattr(routes, "verify_id_token", lambda token: guest)
        try:
            me_response = routes.me(
                authorization="Bearer test-token",
                workspace_id=workspace,
            )
        finally:
            monkeypatch.undo()
        assert me_response["membership_status"] == "active"
        assert me_response["workspace_id"] == workspace
        assert me_response["employee_id"] == context["employee_id"]
        assert me_response["role_ids"] == ["data_analyst"]
        assert me_response["profile_complete"] is False
    finally:
        with SessionLocal.begin() as session:
            session.execute(
                text("DELETE FROM organizations WHERE organization_id=:id"),
                {"id": result["organization_id"]},
            )


def test_supabase_invitation_rejects_expired_and_revoked():
    import uuid
    from datetime import datetime, timedelta, timezone
    from firebase_authz.auth import AuthzError
    from firebase_authz.supabase_provider import (
        accept_invitation,
        create_invitation,
        register_organization,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"expiry-owner-{suffix}"
    guest_uid = f"expiry-guest-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"{owner_uid}@example.com"}
    guest = {"uid": guest_uid, "sub": guest_uid, "email": f"{guest_uid}@example.com"}
    result = _register_organization(owner, f"Expiry Test {suffix}", "Main", f"EXPIRY-{suffix}")
    workspace = result["workspace_id"]
    try:
        expired = create_invitation(
            owner, workspace, guest["email"], "data_analyst",
            int((datetime.now(timezone.utc) + timedelta(hours=1)).timestamp() * 1000),
        )
        with SessionLocal.begin() as session:
            session.execute(
                text("UPDATE invitations SET expires_at=now() WHERE invitation_id=:id"),
                {"id": expired["invitation_id"]},
            )
        with pytest.raises(AuthzError, match="expired"):
            accept_invitation(guest, workspace, expired["invitation_id"])

        revoked = create_invitation(
            owner, workspace, guest["email"], "data_analyst",
        )
        with SessionLocal.begin() as session:
            session.execute(
                text("UPDATE invitations SET status='revoked' WHERE invitation_id=:id"),
                {"id": revoked["invitation_id"]},
            )
        with pytest.raises(AuthzError, match="no longer active"):
            accept_invitation(guest, workspace, revoked["invitation_id"])
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_invitation_rejects_cross_company_active_member():
    import uuid
    from firebase_authz.auth import AuthzError
    from firebase_authz.supabase_provider import (
        accept_invitation,
        create_invitation,
        register_organization,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_a = {"uid": f"cross-owner-a-{suffix}", "sub": f"cross-owner-a-{suffix}",
               "email": f"cross-owner-a-{suffix}@example.com"}
    owner_b = {"uid": f"cross-owner-b-{suffix}", "sub": f"cross-owner-b-{suffix}",
               "email": f"cross-owner-b-{suffix}@example.com"}
    guest_uid = f"cross-guest-{suffix}"
    guest = {"uid": guest_uid, "sub": guest_uid, "email": f"cross-guest-{suffix}@example.com"}
    org_a = _register_organization(owner_a, f"Cross A {suffix}", "A", f"CROSS-A-{suffix}")
    org_b = _register_organization(owner_b, f"Cross B {suffix}", "B", f"CROSS-B-{suffix}")
    invitation_a = create_invitation(owner_a, org_a["workspace_id"], guest["email"], "data_analyst")
    accepted_a = accept_invitation(guest, org_a["workspace_id"], invitation_a["invitation_id"])
    invitation_b = create_invitation(owner_b, org_b["workspace_id"], guest["email"], "data_analyst")
    try:
        with pytest.raises(AuthzError):
            accept_invitation(guest, org_b["workspace_id"], invitation_b["invitation_id"])
        with SessionLocal() as session:
            rows = session.execute(
                text("""SELECT organization_id, status FROM organization_members
                        WHERE employee_id=:employee ORDER BY organization_id"""),
                {"employee": accepted_a["employee_id"]},
            ).all()
        assert rows == [(org_a["organization_id"], "active")]
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": org_a["organization_id"]})
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": org_b["organization_id"]})


def test_supabase_management_approved_employee_and_delegation_are_scoped():
    import uuid
    from firebase_authz.supabase_provider import (
        accept_invitation, create_invitation, management_snapshot,
        register_organization, set_approved_employee, set_delegation,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"scope-owner-{suffix}"
    member_uid = f"member-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"owner-{suffix}@example.com"}
    member = {"uid": member_uid, "sub": member_uid, "email": f"member-{suffix}@example.com"}
    result = _register_organization(owner, "Scope Test", "Main Branch", "SCOPE-TEST")
    workspace = result["workspace_id"]
    try:
        invitation = create_invitation(owner, workspace, member["email"], "team_lead")
        accepted_member = accept_invitation(member, workspace, invitation["invitation_id"])
        assert set_approved_employee(owner, workspace, member_uid, accepted_member["employee_id"]) is True
        delegation = set_delegation(owner, workspace, member_uid, [member_uid], [], ["dataset.share"], None)
        assert delegation["delegation_id"].startswith("dlg_")
        snapshot = management_snapshot(owner, workspace)
        assert any(row["uid"] == member_uid for row in snapshot["members"])
        assert snapshot["approved_employees"][0]["uid"] == member_uid
        assert snapshot["delegations"][0]["delegation_id"] == delegation["delegation_id"]
        with SessionLocal() as session:
            count = session.execute(text("""SELECT count(*) FROM approved_employees
                WHERE organization_id=:org AND workspace_id=:workspace"""),
                                    {"org": workspace, "workspace": workspace}).scalar_one()
        assert count == 1
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_legacy_registration_alias_uses_transactional_provider():
    from firebase_authz.supabase_provider import register_organization
    result = _register_organization({"uid": "legacy-alias-test", "sub": "legacy-alias-test"}, "Legacy Alias", "Main Branch", "LEGACY-ALIAS")
    try:
        assert result["membership_status"] == "active"
    finally:
        from core.db import SessionLocal
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_account_cleanup_revokes_authorization_metadata_transactionally():
    from firebase_authz.auth import AuthzError
    from firebase_authz.supabase_provider import accept_invitation, cleanup_account, create_invitation, register_organization
    from core.db import SessionLocal

    suffix = __import__("uuid").uuid4().hex
    owner_uid = "cleanup-owner-" + suffix
    uid = "cleanup-test-user-" + suffix
    owner = {"uid": owner_uid, "sub": owner_uid, "email": owner_uid + "@example.com"}
    claims = {"uid": uid, "sub": uid, "email": uid + "@example.com"}
    result = _register_organization(owner, "Cleanup Test", "Main Branch", "CLEANUP-TEST")
    invitation = create_invitation(owner, result["workspace_id"], claims["email"], "data_analyst")
    accept_invitation(claims, result["workspace_id"], invitation["invitation_id"])
    try:
        assert cleanup_account(claims, uid) == {"revoked_workspaces": [result["workspace_id"]]}
        with SessionLocal() as session:
            row = session.execute(text("""SELECT m.status, b.status AS binding_status
                FROM organization_members m JOIN identity_bindings b ON b.principal_id=m.principal_id
                WHERE m.organization_id=:org AND b.provider='supabase' AND b.provider_subject=:uid"""),
                                  {"org": result["organization_id"], "uid": uid}).one()
        assert row.status == "removed"
        assert row.binding_status == "inactive"
        with __import__("pytest").raises(AuthzError):
            cleanup_account(claims, uid + "-other")
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_concurrent_employee_id_allocation_is_unique():
    import uuid
    from concurrent.futures import ThreadPoolExecutor
    from core.db import SessionLocal
    from firebase_authz.supabase_provider import _allocate_employee_id

    suffix = uuid.uuid4().hex
    owner_uid = f"counter-owner-{suffix}"
    result = _register_organization(
        {"uid": owner_uid, "sub": owner_uid},
        f"Concurrent Counter {suffix}",
        "Main",
        f"COUNTER-{suffix}",
    )
    try:
        def allocate(_):
            with SessionLocal.begin() as db:
                return _allocate_employee_id(db, result["organization_id"])

        with ThreadPoolExecutor(max_workers=8) as executor:
            employee_ids = list(executor.map(allocate, range(8)))
        assert len(set(employee_ids)) == 8
        assert sorted(int(value[3:]) for value in employee_ids) == list(range(2, 10))
    finally:
        with SessionLocal.begin() as db:
            db.execute(
                text("DELETE FROM organizations WHERE organization_id=:org"),
                {"org": result["organization_id"]},
            )


def test_concurrent_organization_bootstrap_does_not_duplicate_membership():
    import uuid
    from concurrent.futures import ThreadPoolExecutor
    from core.db import SessionLocal
    from firebase_authz.supabase_provider import AuthzError

    suffix = uuid.uuid4().hex
    owner_uid = f"bootstrap-race-{suffix}"
    claims = {"uid": owner_uid, "sub": owner_uid, "email": f"{owner_uid}@example.com"}
    organization_name = f"Concurrent Bootstrap {suffix}"
    branch_identifier = f"BOOTSTRAP-{suffix}"

    def attempt(_):
        try:
            return _register_organization(
                claims, organization_name, "Main", branch_identifier
            )
        except Exception as exc:
            return exc

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(attempt, range(2)))
        successes = [value for value in outcomes if isinstance(value, dict)]
        assert len(successes) == 1
        assert any(isinstance(value, (AuthzError, ValueError)) for value in outcomes)
        with SessionLocal() as db:
            organization_count = db.execute(
                text("SELECT count(*) FROM organizations WHERE name=:name"),
                {"name": organization_name},
            ).scalar_one()
            identity_memberships = db.execute(
                text("""
                    SELECT count(*)
                    FROM organization_members m
                    JOIN identity_bindings b ON b.principal_id=m.principal_id
                    WHERE b.provider='supabase' AND b.provider_subject=:uid
                """),
                {"uid": owner_uid},
            ).scalar_one()
        assert organization_count == 1
        assert identity_memberships == 1
    finally:
        with SessionLocal.begin() as db:
            db.execute(
                text("DELETE FROM organizations WHERE name=:name"),
                {"name": organization_name},
            )


def test_concurrent_invitation_acceptance_is_transactionally_consistent():
    import uuid
    from concurrent.futures import ThreadPoolExecutor
    from core.db import SessionLocal
    from firebase_authz.supabase_provider import accept_invitation, create_invitation

    suffix = uuid.uuid4().hex
    owner_uid = f"accept-owner-{suffix}"
    guest_uid = f"accept-guest-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"{owner_uid}@example.com"}
    guest = {"uid": guest_uid, "sub": guest_uid, "email": f"{guest_uid}@example.com"}
    result = _register_organization(
        owner, f"Concurrent Acceptance {suffix}", "Main", f"ACCEPT-{suffix}"
    )
    invitation = create_invitation(
        owner, result["workspace_id"], guest["email"], "data_analyst"
    )

    def accept(_):
        try:
            return accept_invitation(guest, result["workspace_id"], invitation["invitation_id"])
        except Exception as exc:
            return exc

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(accept, range(2)))
        successes = [value for value in outcomes if isinstance(value, dict) and value.get("accepted") is True]
        assert successes
        with SessionLocal() as db:
            membership_count = db.execute(
                text("""
                    SELECT count(*)
                    FROM organization_members m
                    JOIN identity_bindings b ON b.principal_id=m.principal_id
                    WHERE m.organization_id=:org
                      AND b.provider='supabase' AND b.provider_subject=:uid
                """),
                {"org": result["organization_id"], "uid": guest_uid},
            ).scalar_one()
            role_count = db.execute(
                text("""
                    SELECT count(*)
                    FROM member_roles mr
                    JOIN identity_bindings b ON b.principal_id=mr.principal_id
                    WHERE mr.organization_id=:org
                      AND b.provider='supabase' AND b.provider_subject=:uid
                """),
                {"org": result["organization_id"], "uid": guest_uid},
            ).scalar_one()
        assert membership_count == 1
        assert role_count == 1
    finally:
        with SessionLocal.begin() as db:
            db.execute(
                text("DELETE FROM organizations WHERE organization_id=:org"),
                {"org": result["organization_id"]},
            )



def test_manager_dataset_mutation_requires_explicit_capability_grant(monkeypatch):
    from contextlib import contextmanager
    from firebase_authz import supabase_provider as provider
    from firebase_authz.auth import AuthzError

    context = {
        "workspace_authorized": True,
        "organization_id": "org-test",
        "workspace_id": "workspace-test",
        "principal_id": "manager-principal",
        "role_ids": ["manager"],
        "permissions": [],
    }
    state = {"grant": None, "manager_locations": ["branch-1"], "branch_locations": [], "roles": ["manager"], "dataset_location": "branch-1"}

    class Result:
        def __init__(self, value=None):
            self.value = value

        def mappings(self):
            return self

        def first(self):
            return self.value

        def scalar_one_or_none(self):
            return self.value

        def scalars(self):
            return self

        def all(self):
            return self.value or []

    class FakeDb:
        def execute(self, statement, params=None):
            query = str(statement)
            if "FROM authorization_resources" in query:
                return Result({"resource_type": "dataset", "owner_principal_id": "owner"})
            if "FROM dataset_authorization" in query and "SELECT protected_original" in query:
                return Result({"protected_original": True, "location_id": state["dataset_location"]})
            if "FROM resource_grants" in query:
                return Result(state["grant"])
            if "SELECT role_id FROM member_roles" in query:
                return Result(state["roles"])
            if "role_id='branch_head'" in query:
                return Result(state["branch_locations"])
            if "role_id='manager'" in query:
                return Result(state["manager_locations"])
            raise AssertionError(f"Unexpected authorization query: {query}")

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    @contextmanager
    def fake_session():
        yield FakeDb()

    monkeypatch.setattr(provider, "authorization_context", lambda *_args, **_kwargs: context)
    monkeypatch.setattr(provider, "SessionLocal", lambda: FakeDb())

    claims = {"uid": "manager", "sub": "manager"}
    with pytest.raises(AuthzError, match="explicit dataset.upload grant"):
        provider.authorize_dataset(claims, "workspace-test", "dataset-1", "dataset.upload")

    state["grant"] = ["dataset.upload"]
    assert provider.authorize_dataset(
        claims, "workspace-test", "dataset-1", "dataset.upload"
    )["authorized"]

    state["grant"] = None
    with pytest.raises(AuthzError, match="explicit dataset.upload grant"):
        provider.authorize_dataset(claims, "workspace-test", "dataset-1", "dataset.upload")

    # Copy creation is also a Manager mutation: branch membership alone must
    # not authorize it, and a grant for the wrong branch must not bypass scope.
    with pytest.raises(AuthzError, match="explicit dataset.create_working_copy grant"):
        provider.authorize_dataset(
            claims, "workspace-test", "dataset-1", "dataset.create_working_copy"
        )

    state["grant"] = ["dataset.create_working_copy"]
    state["manager_locations"] = ["branch-2"]
    with pytest.raises(AuthzError, match="outside your Manager scope"):
        provider.authorize_dataset(
            claims, "workspace-test", "dataset-1", "dataset.create_working_copy"
        )

    state["manager_locations"] = ["branch-1"]
    assert provider.authorize_dataset(
        claims, "workspace-test", "dataset-1", "dataset.create_working_copy"
    )["authorized"]

    # Branch Heads do not need a Manager grant, but they must stay within
    # their own assigned branch.
    state["roles"] = ["branch_head"]
    state["branch_locations"] = ["branch-2"]
    with pytest.raises(AuthzError, match="outside your Branch Head scope"):
        provider.authorize_dataset(
            claims, "workspace-test", "dataset-1", "dataset.create_working_copy"
        )

    state["branch_locations"] = ["branch-1"]
    assert provider.authorize_dataset(
        claims, "workspace-test", "dataset-1", "dataset.create_working_copy"
    )["authorized"]



def test_branch_scoped_dataset_catalog_requires_grant_for_unscoped_resources(monkeypatch):
    from firebase_authz import supabase_provider as provider

    context = {
        "organization_id": "org-test",
        "principal_id": "branch-manager",
        "role_ids": ["manager"],
    }
    state = {"unscoped_grant": None}

    class Result:
        def __init__(self, value=None):
            self.value = value

        def mappings(self):
            return self

        def all(self):
            return self.value or []

        def scalar_one_or_none(self):
            return self.value

        def scalars(self):
            return self

    class FakeDb:
        def execute(self, statement, params=None):
            query = str(statement)
            if "FROM dataset_authorization da" in query:
                return Result([
                    {"dataset_id": "branch-dataset", "dataset_name": "Branch", "original_filename": "branch.csv",
                     "location_id": "branch-1", "location_name": "Branch 1"},
                    {"dataset_id": "unscoped-dataset", "dataset_name": "Unscoped", "original_filename": "global.csv",
                     "location_id": None, "location_name": None},
                ])
            if "FROM organizational_assignments" in query:
                return Result(["branch-1"])
            if "FROM resource_grants" in query:
                return Result(state["unscoped_grant"])
            raise AssertionError(f"Unexpected catalog query: {query}")

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    monkeypatch.setattr(provider, "authorization_context", lambda *_args, **_kwargs: context)
    monkeypatch.setattr(provider, "SessionLocal", lambda: FakeDb())

    result = provider.list_dataset_catalog({"uid": "branch-manager"}, "workspace-test")
    assert [row["dataset_id"] for row in result] == ["branch-dataset"]

    state["unscoped_grant"] = ["dataset.view_original"]
    result = provider.list_dataset_catalog({"uid": "branch-manager"}, "workspace-test")
    assert [row["dataset_id"] for row in result] == ["branch-dataset", "unscoped-dataset"]
