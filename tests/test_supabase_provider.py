import os

import pytest
from sqlalchemy import text


pytestmark = pytest.mark.skipif(
    not os.environ.get("DATABASE_URL"), reason="Supabase DATABASE_URL is required"
)


def test_supabase_registration_persists_owner_context():
    from firebase_authz.supabase_provider import register_organization
    from core.db import SessionLocal

    claims = {
        "uid": "integration-test-user",
        "sub": "integration-test-user",
        "firebase": {"sign_in_provider": "password", "identities": {"password": ["integration-test-user"]}},
    }
    result = register_organization(claims, "ABC")
    assert result["organization_id"].startswith("org_")
    assert result["workspace_id"] == result["organization_id"]
    assert result["role_ids"] == ["organization_owner"]

    with SessionLocal() as session:
        connection = session.connection()
        row = connection.execute(text("""SELECT o.name, w.workspace_id, m.employee_id, mr.role_id
            FROM organizations o
            JOIN workspaces w ON w.organization_id = o.organization_id
            JOIN organization_members m ON m.organization_id = o.organization_id
            JOIN member_roles mr ON mr.organization_id = m.organization_id AND mr.principal_id = m.principal_id
            WHERE o.organization_id = :id"""), {"id": result["organization_id"]}).one()
    assert row.name == "ABC"
    assert row.workspace_id == result["workspace_id"]
    assert row.employee_id.startswith("emp_")
    assert row.role_id == "organization_owner"

    with SessionLocal.begin() as session:
        session.execute(text("DELETE FROM organizations WHERE organization_id = :id"), {"id": result["organization_id"]})


def test_supabase_registration_rejects_control_characters():
    from firebase_authz.supabase_provider import register_organization

    with pytest.raises(ValueError):
        register_organization({"uid": "u"}, "bad\nname")


def test_dataset_and_working_copy_authorization_is_workspace_scoped():
    from sqlalchemy import text
    from core.db import SessionLocal
    from firebase_authz.supabase_provider import (
        authorize_dataset,
        authorize_working_copy,
        create_working_copy,
        register_dataset,
        register_organization,
    )

    claims = {"uid": "dataset-test-user", "sub": "dataset-test-user",
              "firebase": {"sign_in_provider": "password", "identities": {"password": ["dataset-test-user"]}}}
    result = register_organization(claims, "Dataset Test")
    register_dataset(claims, result["workspace_id"], "ds_test", "dataset-test-user")
    assert authorize_dataset(claims, result["workspace_id"], "ds_test", "dataset.view_original")["authorized"]
    create_working_copy(claims, result["workspace_id"], "ds_test", "wc_test", "1")
    assert authorize_working_copy(claims, result["workspace_id"], "wc_test", "working_copy.modify")["authorized"]
    from firebase_authz.service import AuthzError
    with pytest.raises(AuthzError):
        authorize_dataset(claims, "org_other", "ds_test", "dataset.view_original")
    with SessionLocal.begin() as session:
        session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_invitation_acceptance_membership_and_role_are_transactional():
    import uuid
    from firebase_authz.service import AuthzError
    from firebase_authz.supabase_provider import (
        accept_invitation, create_invitation, mutate_role, pending_invitations,
        register_organization, set_membership_status,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"invite-owner-{suffix}"
    guest_uid = f"invite-guest-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"owner-{suffix}@example.com",
             "firebase": {"sign_in_provider": "password", "identities": {"password": [owner_uid]}}}
    guest = {"uid": guest_uid, "sub": guest_uid, "email": f"guest-{suffix}@example.com",
             "firebase": {"sign_in_provider": "password", "identities": {"password": [guest_uid]}}}
    result = register_organization(owner, "Invitation Test")
    workspace = result["workspace_id"]
    try:
        invitation = create_invitation(owner, workspace, guest["email"], "emp_guest", "employee")
        assert pending_invitations(guest)[0]["invitation_id"] == invitation["invitation_id"]
        accepted = accept_invitation(guest, workspace, invitation["invitation_id"])
        assert accepted["accepted"] is True
        with SessionLocal() as db:
            row = db.execute(text("""SELECT m.status, mr.role_id FROM organization_members m
                JOIN identity_bindings b ON b.principal_id=m.principal_id
                JOIN member_roles mr ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
                    WHERE m.organization_id=:org AND b.firebase_uid=:uid"""),
                           {"org": workspace, "uid": guest_uid}).one()
        assert row.status == "active"
        assert row.role_id == "employee"
        assert set_membership_status(owner, workspace, guest_uid, "suspended") is True
        with pytest.raises(AuthzError):
            mutate_role(guest, workspace, owner_uid, "manager", True)
        with pytest.raises(AuthzError):
            accept_invitation(guest, "org_wrong", invitation["invitation_id"])
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_management_approved_employee_and_delegation_are_scoped():
    import uuid
    from firebase_authz.supabase_provider import (
        accept_invitation, create_invitation, management_snapshot,
        register_organization, set_approved_employee, set_delegation,
    )
    from core.db import SessionLocal

    suffix = uuid.uuid4().hex
    owner_uid = f"scope-owner-{suffix}"
    member_uid = f"scope-member-{suffix}"
    owner = {"uid": owner_uid, "sub": owner_uid, "email": f"owner-{suffix}@example.com",
             "firebase": {"sign_in_provider": "password", "identities": {"password": [owner_uid]}}}
    member = {"uid": member_uid, "sub": member_uid, "email": f"member-{suffix}@example.com",
              "firebase": {"sign_in_provider": "password", "identities": {"password": [member_uid]}}}
    result = register_organization(owner, "Scope Test")
    workspace = result["workspace_id"]
    try:
        invitation = create_invitation(owner, workspace, member["email"], "emp_member", "team_lead")
        accept_invitation(member, workspace, invitation["invitation_id"])
        assert set_approved_employee(owner, workspace, member_uid, "emp_member") is True
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
    result = register_organization({"uid": "legacy-alias-test", "sub": "legacy-alias-test"}, "Legacy Alias")
    try:
        assert result["membership_status"] == "active"
    finally:
        from core.db import SessionLocal
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})


def test_supabase_account_cleanup_revokes_authorization_metadata_transactionally():
    from firebase_authz.service import AuthzError
    from firebase_authz.supabase_provider import accept_invitation, cleanup_account, create_invitation, register_organization
    from core.db import SessionLocal

    suffix = __import__("uuid").uuid4().hex
    owner_uid = "cleanup-owner-" + suffix
    uid = "cleanup-test-user-" + suffix
    owner = {"uid": owner_uid, "sub": owner_uid, "email": owner_uid + "@example.com",
             "firebase": {"sign_in_provider": "password", "identities": {"password": [owner_uid]}}}
    claims = {"uid": uid, "sub": uid, "email": uid + "@example.com",
              "firebase": {"sign_in_provider": "password", "identities": {"password": [uid]}}}
    result = register_organization(owner, "Cleanup Test")
    invitation = create_invitation(owner, result["workspace_id"], claims["email"], "emp_cleanup", "employee")
    accept_invitation(claims, result["workspace_id"], invitation["invitation_id"])
    try:
        assert cleanup_account(claims, uid) == {"revoked_workspaces": [result["workspace_id"]]}
        with SessionLocal() as session:
            row = session.execute(text("""SELECT m.status, b.status AS binding_status
                FROM organization_members m JOIN identity_bindings b ON b.principal_id=m.principal_id
                WHERE m.organization_id=:org AND b.firebase_uid=:uid"""),
                                  {"org": result["organization_id"], "uid": uid}).one()
        assert row.status == "removed"
        assert row.binding_status == "inactive"
        with __import__("pytest").raises(AuthzError):
            cleanup_account(claims, uid + "-other")
    finally:
        with SessionLocal.begin() as session:
            session.execute(text("DELETE FROM organizations WHERE organization_id=:id"), {"id": result["organization_id"]})
