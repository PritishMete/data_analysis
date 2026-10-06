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
    def __init__(self, roles, grant=None, manager_locations=None, branch_locations=None):
        self.roles = roles
        self.grant = grant
        self.manager_locations = manager_locations or []
        self.branch_locations = branch_locations or []

    def execute(self, statement, params=None):
        sql = str(statement)
        if "FROM authorization_resources" in sql:
            return _Result(row={"resource_type": "dataset", "owner_principal_id": "owner"})
        if "FROM dataset_authorization" in sql:
            return _Result(row={"protected_original": True, "location_id": "branch-1"})
        if "FROM resource_grants" in sql:
            return _Result(scalar=self.grant)
        if "FROM member_roles" in sql:
            return _Result(scalars=self.roles)
        if "role_id='branch_head'" in sql:
            return _Result(scalars=self.branch_locations)
        if "role_id='manager'" in sql:
            return _Result(scalars=self.manager_locations)
        raise AssertionError(f"Unexpected authorization query: {sql}")


class _SessionFactory:
    def __init__(self, db):
        self.db = db

    def __call__(self):
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


def test_manager_can_upload_within_assigned_branch(monkeypatch):
    db = _Db(["manager"], manager_locations=["branch-1"])
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
