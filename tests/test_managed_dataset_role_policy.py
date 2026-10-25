import pytest

from firebase_authz import supabase_provider


class _Result:
    def __init__(self, *, row=None, scalar=None, scalars=None):
        self._row = row
        self._scalar = scalar
        self._scalars = scalars or []

    def mappings(self):
        return self

    def first(self):
        return self._row

    def scalar_one_or_none(self):
        return self._scalar

    def scalars(self):
        return self

    def all(self):
        return self._scalars


class _Db:
    def __init__(
        self, roles, grant=None, manager_locations=None, branch_locations=None,
        protected=True, location_id="branch-1",
    ):
        self.roles = roles
        self.grant = grant
        self.manager_locations = manager_locations or []
        self.branch_locations = branch_locations or []
        self.protected = protected
        self.location_id = location_id

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        if "FROM authorization_resources" in sql:
            return _Result(row={"resource_type": "dataset", "owner_principal_id": "owner"})
        if "FROM dataset_authorization" in sql:
            return _Result(row={"protected_original": self.protected, "location_id": self.location_id})
        if "FROM resource_grants" in sql:
            return _Result(scalar=self.grant)
        if "FROM member_roles" in sql:
            return _Result(scalars=self.roles)
        if "role_id='branch_head'" in sql or (
            "FROM organizational_assignments oa" in sql
            and (params or {}).get("role") == "branch_head"
        ):
            return _Result(scalars=self.branch_locations)
        if "role_id='manager'" in sql or (
            "FROM organizational_assignments oa" in sql
            and (params or {}).get("role") == "manager"
        ):
            return _Result(scalars=self.manager_locations)
        raise AssertionError(f"Unexpected authorization query: {sql}")


class _SessionFactory:
    def __init__(self, db):
        self.db = db

    def __call__(self):
        return self.db

    def begin(self):
        return self.db


def _context(roles):
    return {
        "workspace_authorized": True,
        "workspace_id": "workspace-1",
        "organization_id": "org-1",
        "principal_id": "principal-1",
        "role_ids": roles,
        "permissions": ["dataset.upload"] if "manager" in roles else [],
    }


@pytest.mark.parametrize(
    "grant",
    [None, [], ["dataset.view_original"], ["dataset.upload"]],
)
def test_manager_cannot_replace_protected_original_without_explicit_grant(monkeypatch, grant):
    db = _Db(["manager"], grant=grant, manager_locations=["branch-1"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="dataset.upload_original"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.upload",
        )


def test_manager_can_replace_protected_original_with_explicit_grant(monkeypatch):
    db = _Db(
        ["manager"],
        grant=["dataset.upload_original"],
        manager_locations=["branch-1"],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "dataset.upload",
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-1"


def test_manager_can_upload_ordinary_dataset_without_replacement_grant(monkeypatch):
    db = _Db(["manager"], manager_locations=["branch-1"], protected=False)
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
        "workspace-1",
        "dataset-ordinary",
        "dataset.upload",
    )

    assert result["authorized"] is True


def test_manager_with_grant_still_cannot_replace_another_branch_dataset(monkeypatch):
    db = _Db(
        ["manager"],
        grant=["dataset.upload_original"],
        manager_locations=["branch-b"],
        location_id="branch-a",
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="outside your Manager scope"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.upload",
        )


def test_organization_owner_keeps_scoped_upload_authority_without_manager_grant(monkeypatch):
    db = _Db(["organization_owner"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: {
            **_context(["organization_owner"]),
            "permissions": ["dataset.upload", "dataset.manage_acl"],
        },
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "owner-1", "sub": "owner-1", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "dataset.upload",
    )

    assert result["authorized"] is True


def test_branch_head_can_upload_original_within_assigned_branch_without_manager_grant(monkeypatch):
    db = _Db(["branch_head"], branch_locations=["branch-1"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: {
            **_context(["branch_head"]),
            "permissions": ["dataset.upload"],
        },
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "head-1", "sub": "head-1", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "dataset.upload",
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-1"


@pytest.mark.parametrize("role", ["employee", "team_lead", "data_analyst", "data_scientist", "data_quality_analyst"])
def test_non_manager_roles_cannot_upload(monkeypatch, role):
    db = _Db([role])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context([role]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="Only a Manager, Branch Head, or Organization Owner"):
        supabase_provider.authorize_dataset(
            {"uid": "member-1", "sub": "member-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.upload",
        )


def test_member_can_create_copy_only_when_explicitly_granted(monkeypatch):
    db = _Db(["team_lead"], grant=["dataset.create_working_copy"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["team_lead"]),
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "lead-1", "sub": "lead-1", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "dataset.create_working_copy",
    )

    assert result["authorized"] is True


def test_member_without_copy_grant_cannot_create_copy(monkeypatch):
    db = _Db(["team_lead"], grant=[])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["team_lead"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="has not been authorized for copying"):
        supabase_provider.authorize_dataset(
            {"uid": "lead-1", "sub": "lead-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.create_working_copy",
        )


class _GrantDb:
    def __init__(self, *, actor_location="branch-1", target_principal="manager-principal",
                 target_manager_active=True):
        self.actor_location = actor_location
        self.target_principal = target_principal
        self.target_manager_active = target_manager_active
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def begin(self):
        return self

    def execute(self, statement, params=None):
        sql = str(statement)
        params = params or {}
        self.calls.append((sql, params))
        if "FROM dataset_authorization" in sql:
            return _Result(row={"location_id": "branch-1", "protected_original": True})
        if "FROM identity_bindings b" in sql and "JOIN organization_members m" in sql:
            return _Result(scalar=self.target_principal)
        if "FROM organizational_assignments oa" in sql and "oa.role_id='manager'" in sql:
            return _Result(scalar=1 if self.target_manager_active else None)
        if "SELECT 1 FROM authorization_resources" in sql:
            return _Result(scalar=1)
        if "FROM organizational_assignments oa" in sql and "role_id='branch_head'" in sql:
            return _Result(scalars=[self.actor_location] if self.actor_location else [])
        if "INSERT INTO resource_grants" in sql:
            return _Result()
        raise AssertionError(f"Unexpected grant query: {sql}")


def _grantor_context(role="branch_head"):
    return {
        "workspace_authorized": True,
        "workspace_id": "workspace-1",
        "organization_id": "org-1",
        "principal_id": "head-principal" if role == "branch_head" else "manager-principal",
        "role_ids": [role],
        "permissions": ["dataset.manage_acl"] if role in {"branch_head", "organization_owner"} else ["dataset.upload"],
    }


def test_branch_head_can_grant_protected_replacement_to_same_branch_manager(monkeypatch):
    db = _GrantDb()
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)

    result = supabase_provider.set_dataset_grant(
        {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "manager-uid",
        ["dataset.upload_original"],
    )

    assert result is True
    target_check = next(params for sql, params in db.calls if "FROM organizational_assignments oa" in sql and "oa.role_id='manager'" in sql)
    assert target_check["location"] == "branch-1"


def test_branch_head_cannot_grant_protected_replacement_to_other_branch_manager(monkeypatch):
    db = _GrantDb(target_manager_active=False)
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)

    with pytest.raises(supabase_provider.AuthzError, match="same branch"):
        supabase_provider.set_dataset_grant(
            {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "manager-uid",
            ["dataset.upload_original"],
        )


def test_manager_cannot_issue_protected_replacement_grants(monkeypatch):
    db = _GrantDb(target_principal="manager-principal")
    context = _grantor_context("manager")
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)

    with pytest.raises(supabase_provider.AuthzError, match="Only a Branch Head or Organization Owner"):
        supabase_provider.set_dataset_grant(
            {"uid": "manager-uid", "sub": "manager-uid", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "manager-uid",
            ["dataset.upload_original"],
        )


def test_branch_head_cannot_grant_protected_replacement_to_self(monkeypatch):
    db = _GrantDb(target_principal="head-principal")
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)

    with pytest.raises(supabase_provider.AuthzError, match="another active Manager"):
        supabase_provider.set_dataset_grant(
            {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "head-uid",
            ["dataset.upload_original"],
        )


def test_branch_head_can_revoke_protected_replacement_grant(monkeypatch):
    db = _GrantDb()
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)

    result = supabase_provider.set_dataset_grant(
        {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
        "workspace-1",
        "dataset-1",
        "manager-uid",
        [],
    )

    assert result is True
    grant_write = next(params for sql, params in db.calls if "INSERT INTO resource_grants" in sql)
    assert grant_write["permissions"] == "[]"
