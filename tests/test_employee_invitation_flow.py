import uuid

import pytest
from sqlalchemy import text

from core.db import SessionLocal
from firebase_authz.service import AuthzError
from firebase_authz.supabase_provider import (
    accept_invitation,
    create_invitation,
    mark_invitation_password_setup,
    register_organization,
)


def _claims(prefix: str, suffix: str, email: str) -> dict:
    uid = f"{prefix}-{suffix}"
    return {
        "uid": uid,
        "sub": uid,
        "email": email,
        "email_verified": True,
        "firebase": {
            "sign_in_provider": "password",
            "identities": {"password": [uid]},
        },
    }


def _cleanup(organization_id: str) -> None:
    with SessionLocal.begin() as db:
        db.execute(
            text("DELETE FROM organizations WHERE organization_id=:id"),
            {"id": organization_id},
        )


def test_employee_invitation_calls_supabase_auth_and_records_delivery(monkeypatch):
    suffix = uuid.uuid4().hex
    owner = _claims("employee-invite-owner", suffix, f"owner-{suffix}@example.com")
    guest_email = f"employee-{suffix}@example.com"
    result = register_organization(owner, f"Invite Flow {suffix}", "Main", f"INV-{suffix}", full_name="Test Owner", phone="+919876543210", address_line1="1 Test Street", state="West Bengal", postal_code="700001", country="India", country_code="IN", state_code="WB", id_proof_type="passport", id_proof_number=f"P{suffix[:8]}")
    workspace = result["workspace_id"]

    calls = []

    def fake_invite(email, redirect_to):
        calls.append((email, redirect_to))
        return {"user_id": f"auth-{suffix}", "email_confirmed": False}

    monkeypatch.setattr(
        "firebase_authz.supabase_provider.invite_user_by_email",
        fake_invite,
    )

    try:
        invitation = create_invitation(owner, workspace, guest_email, "employee")
        assert calls == [
            (
                guest_email,
                "https://pritishmete.github.io/data_analysis/employee-invite",
            )
        ]
        assert invitation["email_delivery_status"] == "initiated"
        with SessionLocal() as db:
            row = db.execute(
                text("""SELECT auth_user_id, email_delivery_status, password_setup_at
                        FROM invitations WHERE invitation_id=:id"""),
                {"id": invitation["invitation_id"]},
            ).one()
        assert row.auth_user_id == f"auth-{suffix}"
        assert row.email_delivery_status == "initiated"
        assert row.password_setup_at is None
    finally:
        _cleanup(result["organization_id"])


def test_existing_confirmed_auth_account_is_not_duplicated(monkeypatch):
    suffix = uuid.uuid4().hex
    owner = _claims("existing-owner", suffix, f"owner-{suffix}@example.com")
    guest_email = f"existing-{suffix}@example.com"
    result = register_organization(owner, f"Existing Flow {suffix}", "Main", f"EX-{suffix}", full_name="Test Owner", phone="+919876543210", address_line1="1 Test Street", state="West Bengal", postal_code="700001", country="India", id_proof_type="passport", id_proof_number=f"P{suffix[:8]}")
    workspace = result["workspace_id"]

    def fail_invite(email, redirect_to):
        raise RuntimeError("User already registered")

    monkeypatch.setattr(
        "firebase_authz.supabase_provider.invite_user_by_email",
        fail_invite,
    )
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.find_user_by_email",
        lambda email: {"user_id": "existing-auth-user", "email_confirmed": True},
    )

    try:
        invitation = create_invitation(owner, workspace, guest_email, "employee")
        assert invitation["email_delivery_status"] == "existing_account"
        assert invitation["password_setup_required"] is False
        with SessionLocal() as db:
            row = db.execute(
                text("SELECT auth_user_id FROM invitations WHERE invitation_id=:id"),
                {"id": invitation["invitation_id"]},
            ).one()
        assert row.auth_user_id == "existing-auth-user"
    finally:
        _cleanup(result["organization_id"])


def test_invitation_acceptance_uses_persisted_organization_and_marks_password_setup(monkeypatch):
    suffix = uuid.uuid4().hex
    owner = _claims("accept-owner", suffix, f"owner-{suffix}@example.com")
    guest = _claims("accept-guest", suffix, f"guest-{suffix}@example.com")
    result = register_organization(owner, f"Accept Flow {suffix}", "Main", f"AC-{suffix}", full_name="Test Owner", phone="+919876543210", address_line1="1 Test Street", state="West Bengal", postal_code="700001", country="India", id_proof_type="passport", id_proof_number=f"P{suffix[:8]}")
    workspace = result["workspace_id"]
    monkeypatch.setattr(
        "firebase_authz.supabase_provider.invite_user_by_email",
        lambda email, redirect_to: {"user_id": f"auth-{email}", "email_confirmed": False},
    )

    try:
        invitation = create_invitation(
            owner,
            workspace,
            guest["email"],
            "employee",
            expires_at=None,
        )
        # The password checkpoint is tied only to the persisted invitation and
        # authenticated email. No workspace value is required from the client.
        marked = mark_invitation_password_setup(guest, invitation["invitation_id"])
        assert marked["organization_id"] == workspace

        accepted = accept_invitation(guest, None, invitation["invitation_id"])
        assert accepted["accepted"] is True
        assert accepted["organization_id"] == workspace
        with SessionLocal() as db:
            row = db.execute(
                text("""SELECT status, password_setup_at
                        FROM invitations WHERE invitation_id=:id"""),
                {"id": invitation["invitation_id"]},
            ).one()
        assert row.status == "accepted"
        assert row.password_setup_at is not None

        wrong = _claims("wrong-user", suffix, f"wrong-{suffix}@example.com")
        with pytest.raises(AuthzError, match="identity"):
            # Create a fresh invitation for the mismatch check.
            second = create_invitation(owner, workspace, wrong["email"], "employee")
            accept_invitation(guest, None, second["invitation_id"])
    finally:
        _cleanup(result["organization_id"])
