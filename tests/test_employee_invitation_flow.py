import pytest


class _FakeResult:
    def __init__(self, mapping=None, scalar=None):
        self._mapping = mapping
        self._scalar = scalar

    def mappings(self):
        return self

    def first(self):
        return self._mapping

    def scalar_one_or_none(self):
        return self._scalar

    def scalars(self):
        return self

    def all(self):
        return [self._scalar] if self._scalar is not None else []


class _FakeDb:
    def __init__(self, actor, *, fail_insert=False):
        self.actor = actor
        self.fail_insert = fail_insert
        self.inserts = []

    def execute(self, statement, params=None):
        sql = str(statement)
        if "SELECT b.principal_id" in sql:
            return _FakeResult(mapping=self.actor)
        if "role_permissions" in sql:
            return _FakeResult(scalar=1)
        if "SELECT DISTINCT location_id" in sql and "FROM organizational_assignments" in sql:
            return _FakeResult(scalar="loc_main")
        if "SELECT 1 FROM organizational_assignments" in sql:
            return _FakeResult(scalar=1)
        if "FROM locations" in sql:
            if "SELECT location_id, status" in sql:
                return _FakeResult(mapping={"location_id": "loc_main", "status": "active"})
            return _FakeResult(scalar="loc_main")
        if "FROM member_roles" in sql:
            return _FakeResult(scalar="organization_owner")
        if "FROM organizations" in sql:
            return _FakeResult(scalar="Test Organization")
        if "INSERT INTO invitations" in sql:
            if self.fail_insert:
                raise RuntimeError("database insert failed")
            self.inserts.append(dict(params or {}))
            return _FakeResult()
        return _FakeResult()


class _FakeContext:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        return self.db

    def __exit__(self, exc_type, exc, tb):
        return False


def _patch_invitation_db(monkeypatch, db):
    import firebase_authz.supabase_provider as provider

    monkeypatch.setattr(provider, "SessionLocal", lambda: _FakeContext(db))

    class _Begin:
        def __enter__(self):
            return db

        def __exit__(self, exc_type, exc, tb):
            return False

    monkeypatch.setattr(provider.SessionLocal, "begin", lambda: _Begin(), raising=False)


def _claims():
    return {
        "uid": "actor-user",
        "sub": "actor-user",
        "email": "actor@example.com",
        "firebase": {
            "sign_in_provider": "password",
            "identities": {"password": ["actor-user"]},
        },
    }


def _actor():
    return {"principal_id": "prn_actor", "employee_id": "EMP001", "status": "active"}


def test_new_email_creates_invitation_with_new_auth_user(monkeypatch):
    import firebase_authz.supabase_provider as provider

    db = _FakeDb(_actor())
    _patch_invitation_db(monkeypatch, db)
    monkeypatch.setattr(
        provider,
        "invite_user_by_email",
        lambda email, redirect_to, **kwargs: {
            "user_id": "auth-new-user",
            "email_confirmed": False,
        },
    )
    monkeypatch.setattr(
        provider,
        "find_user_by_email",
        lambda email: pytest.fail("existing-user lookup must not run for a new Auth user"),
    )

    result = provider.create_invitation(
        _claims(), "org_test", "new@example.com", "data_analyst", location_id="loc_main"
    )

    assert result["status"] == "invited"
    assert result["email_delivery_status"] == "initiated"
    assert result["password_setup_required"] is True
    assert db.inserts[0]["auth_user"] == "auth-new-user"


def test_existing_confirmed_auth_user_creates_existing_account_invitation(monkeypatch):
    import firebase_authz.supabase_provider as provider

    db = _FakeDb(_actor())
    _patch_invitation_db(monkeypatch, db)

    class DuplicateError(Exception):
        status_code = 422

        def __str__(self):
            return "A user with this email address has already been registered"

    calls = {"invite": 0}

    def duplicate_invite(email, redirect_to, **kwargs):
        calls["invite"] += 1
        raise DuplicateError()

    monkeypatch.setattr(provider, "invite_user_by_email", duplicate_invite)
    monkeypatch.setattr(
        provider,
        "find_user_by_email",
        lambda email: {
            "user_id": "auth-existing-user",
            "email_confirmed": True,
        },
    )

    result = provider.create_invitation(
        _claims(), "org_test", "existing@example.com", "data_analyst"
    )

    assert calls["invite"] == 1
    assert result["email_delivery_status"] == "existing_account"
    assert result["password_setup_required"] is False
    assert db.inserts[0]["auth_user"] == "auth-existing-user"


def test_existing_unconfirmed_auth_user_is_rejected_without_local_invitation(monkeypatch):
    import firebase_authz.supabase_provider as provider
    from firebase_authz.service import AuthzError

    db = _FakeDb(_actor())
    _patch_invitation_db(monkeypatch, db)

    class DuplicateError(Exception):
        status_code = 422

        def __str__(self):
            return "A user with this email address has already been registered"

    monkeypatch.setattr(provider, "invite_user_by_email", lambda *_: (_ for _ in ()).throw(DuplicateError()))
    monkeypatch.setattr(
        provider,
        "find_user_by_email",
        lambda email: {"user_id": "auth-unconfirmed", "email_confirmed": False},
    )

    with pytest.raises(AuthzError, match="unconfirmed Auth account"):
        provider.create_invitation(
            _claims(), "org_test", "unconfirmed@example.com", "data_analyst", location_id="loc_main"
        )

    assert db.inserts == []


def test_database_insertion_failure_does_not_return_success(monkeypatch):
    import firebase_authz.supabase_provider as provider

    db = _FakeDb(_actor(), fail_insert=True)
    _patch_invitation_db(monkeypatch, db)
    monkeypatch.setattr(
        provider,
        "invite_user_by_email",
        lambda email, redirect_to, **kwargs: {"user_id": "auth-new-user", "email_confirmed": False},
    )

    with pytest.raises(RuntimeError, match="database insert failed"):
        provider.create_invitation(
            _claims(), "org_test", "db-failure@example.com", "data_analyst"
        )
