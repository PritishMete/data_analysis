import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import pytest

from firebase_authz.invitation_email_sender import (
    InvitationEmailSenderNotConfigured,
    send_invitation_email,
)


class FakeResult:
    def __init__(self, mapping=None, scalar=None):
        self.mapping = mapping
        self.scalar = scalar

    def mappings(self):
        return self

    def first(self):
        return self.mapping

    def scalar_one_or_none(self):
        return self.scalar

    def scalars(self):
        return self

    def all(self):
        return [self.scalar] if self.scalar is not None else []


class FakeDb:
    def __init__(self, *, invitation=None):
        self.invitation = invitation
        self.statements = []
        self.inserts = []

    def execute(self, statement, params=None):
        sql = str(statement)
        self.statements.append((sql, dict(params or {})))
        if "SELECT b.principal_id" in sql:
            return FakeResult(mapping={"principal_id": "prn_actor", "status": "active"})
        if "FROM member_roles" in sql:
            return FakeResult(scalar="organization_owner")
        if "FROM organizations" in sql:
            return FakeResult(scalar="Example Org")
        if "SELECT location_id, status FROM locations" in sql:
            return FakeResult(mapping={"location_id": "loc_main", "status": "active"})
        if "FROM invitations" in sql and "WHERE token_hash=:token_hash" in sql:
            return FakeResult(mapping=self.invitation)
        if "INSERT INTO invitations" in sql:
            self.inserts.append(dict(params or {}))
        return FakeResult()


class FakeContext:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        return self.db

    def __exit__(self, exc_type, exc, tb):
        return False


def patch_db(monkeypatch, db):
    import firebase_authz.supabase_provider as provider

    monkeypatch.setattr(provider, "SessionLocal", lambda: FakeContext(db))

    class Begin:
        def __enter__(self):
            return db

        def __exit__(self, exc_type, exc, tb):
            return False

    monkeypatch.setattr(provider.SessionLocal, "begin", lambda: Begin(), raising=False)


def test_sender_fails_closed_without_configuration(monkeypatch):
    monkeypatch.delenv("INSIGHTFLOW_INVITATION_EMAIL_SENDER", raising=False)
    with pytest.raises(InvitationEmailSenderNotConfigured):
        send_invitation_email(
            email="employee@example.com",
            invitation_url="https://example.invalid/employee-invite?token=opaque",
            organization_name="Example",
            role_id="data_analyst",
        )


def test_token_hash_is_fixed_length_and_does_not_equal_raw_token():
    token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    assert len(token) >= 40
    assert digest != token
    assert len(digest) == 64


def test_invitation_creation_does_not_call_supabase_auth_or_store_raw_token(monkeypatch):
    import firebase_authz.supabase_provider as provider

    db = FakeDb()
    patch_db(monkeypatch, db)
    monkeypatch.delenv("INSIGHTFLOW_INVITATION_EMAIL_SENDER", raising=False)
    monkeypatch.setattr(provider, "invite_user_by_email", lambda *a, **k: pytest.fail("must not create Auth user at send time"))
    monkeypatch.setattr(provider, "find_user_by_email", lambda *a, **k: pytest.fail("must not look up/create Auth user at send time"))
    monkeypatch.setattr(provider, "_principal_for_claims", lambda *a, **k: {"principal_id": "prn_actor", "status": "active"})

    result = provider.create_invitation(
        {
            "uid": "actor", "sub": "actor", "email": "owner@example.com",
            "firebase": {"sign_in_provider": "password", "identities": {"password": ["actor"]}},
        },
        "org_test", "new@example.com", "data_analyst", location_id="loc_main",
    )
    assert result["status"] == "invited"
    assert result["email_delivery_status"] == "sender_configuration_required"
    assert "auth_user" not in db.inserts[0]
    assert len(db.inserts[0]["token_hash"]) == 64
    assert "token" not in db.inserts[0]


@pytest.mark.parametrize("status", ["accepted", "revoked", "redeeming"])
def test_redeem_rejects_used_revoked_or_concurrently_redeemed_tokens(monkeypatch, status):
    import firebase_authz.supabase_provider as provider
    from firebase_authz.service import AuthzError

    token = secrets.token_urlsafe(32)
    db = FakeDb(invitation={
        "invitation_id": "inv_1", "organization_id": "org_1",
        "email": "employee@example.com", "status": status,
        "expires_at": datetime.now(timezone.utc) + timedelta(hours=1),
        "auth_user_id": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
    })
    patch_db(monkeypatch, db)
    with pytest.raises(AuthzError):
        provider.redeem_invitation(token, "valid-password")


def test_redeem_rejects_expired_token_before_auth_user_creation(monkeypatch):
    import firebase_authz.supabase_provider as provider
    from firebase_authz.service import AuthzError

    token = secrets.token_urlsafe(32)
    db = FakeDb(invitation={
        "invitation_id": "inv_1", "organization_id": "org_1",
        "email": "employee@example.com", "status": "invited",
        "expires_at": datetime.now(timezone.utc) - timedelta(seconds=1),
        "auth_user_id": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
    })
    patch_db(monkeypatch, db)
    monkeypatch.setattr(provider, "create_user_with_password", lambda *a: pytest.fail("expired token must not create user"))
    with pytest.raises(AuthzError, match="expired"):
        provider.redeem_invitation(token, "valid-password")


def test_redeem_rejects_malformed_token_before_database_access(monkeypatch):
    import firebase_authz.supabase_provider as provider
    from firebase_authz.service import AuthzError

    with pytest.raises(AuthzError, match="invalid or expired"):
        provider.redeem_invitation("short", "valid-password")


def test_password_minimum_is_enforced_before_auth_user_creation(monkeypatch):
    import firebase_authz.supabase_provider as provider

    with pytest.raises(ValueError, match="at least 8"):
        provider.redeem_invitation("x" * 48, "short")


def test_repeated_invitation_rotates_token_and_revokes_previous_pending(monkeypatch):
    import firebase_authz.supabase_provider as provider

    db = FakeDb()
    patch_db(monkeypatch, db)
    monkeypatch.delenv("INSIGHTFLOW_INVITATION_EMAIL_SENDER", raising=False)
    monkeypatch.setattr(provider, "_principal_for_claims", lambda *a, **k: {"principal_id": "prn_actor", "status": "active"})
    monkeypatch.setattr(provider, "invite_user_by_email", lambda *a, **k: pytest.fail("must not create Auth user"))
    claims = {
        "uid": "actor", "sub": "actor", "email": "owner@example.com",
        "firebase": {"sign_in_provider": "password", "identities": {"password": ["actor"]}},
    }
    provider.create_invitation(claims, "org_test", "new@example.com", "data_analyst", location_id="loc_main")
    provider.create_invitation(claims, "org_test", "new@example.com", "data_analyst", location_id="loc_main")

    hashes = [params["token_hash"] for params in db.inserts]
    assert len(hashes) == 2
    assert hashes[0] != hashes[1]
    assert any("SET status='revoked'" in sql for sql, _ in db.statements)


def test_existing_registered_email_is_not_duplicated_or_auto_linked(monkeypatch):
    import firebase_authz.supabase_provider as provider
    from firebase_authz.service import AuthzError

    token = secrets.token_urlsafe(32)
    db = FakeDb(invitation={
        "invitation_id": "inv_existing", "organization_id": "org_1",
        "email": "existing@example.com", "status": "invited",
        "expires_at": datetime.now(timezone.utc) + timedelta(hours=1),
        "auth_user_id": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
    })
    patch_db(monkeypatch, db)
    monkeypatch.setattr(provider, "find_user_by_email", lambda email: {"user_id": "already-registered", "email_confirmed": True})
    monkeypatch.setattr(provider, "create_user_with_password", lambda *a: pytest.fail("existing account must not be duplicated"))
    with pytest.raises(AuthzError, match="already has a Supabase account"):
        provider.redeem_invitation(token, "valid-password")


def test_existing_verified_session_redeems_invitation_without_creating_user(monkeypatch):
    import firebase_authz.supabase_provider as provider

    token = secrets.token_urlsafe(32)
    db = FakeDb(invitation={
        "invitation_id": "inv_existing", "organization_id": "org_1",
        "email": "existing@example.com", "status": "invited",
        "expires_at": datetime.now(timezone.utc) + timedelta(hours=1),
        "auth_user_id": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
    })
    patch_db(monkeypatch, db)
    monkeypatch.setattr(provider, "find_user_by_email", lambda email: {"user_id": "existing-user", "email_confirmed": True})
    monkeypatch.setattr(provider, "create_user_with_password", lambda *a: pytest.fail("existing user must not be created again"))
    accepted = {"accepted": True, "organization_id": "org_1", "employee_id": "EMP010", "location_id": "loc_main"}
    monkeypatch.setattr(provider, "accept_invitation", lambda claims, org, invitation_id: accepted)
    claims = {"uid": "existing-user", "sub": "existing-user", "email": "existing@example.com", "email_verified": True, "provider": "supabase"}

    result = provider.redeem_invitation(token, "", claims)

    assert result["accepted"] is True
    assert any("SET auth_user_id=:uid" in sql for sql, _ in db.statements)
