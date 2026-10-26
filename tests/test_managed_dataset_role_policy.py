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
        protected=True, location_id="branch-1", owner_locations=None,
        manager_upload_grants=None,
    ):
        self.roles = roles
        self.grant = grant
        self.manager_locations = manager_locations or []
        self.manager_upload_grants = (
            self.manager_locations if manager_upload_grants is None else manager_upload_grants
        )
        self.branch_locations = branch_locations or []
        self.owner_locations = ["branch-1"] if owner_locations is None else owner_locations
        self.protected = protected
        self.location_id = location_id

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        params = params or {}
        if "FROM manager_dataset_upload_grants g" in sql:
            return _Result(scalars=self.manager_upload_grants)
        if "FROM organizational_assignments oa" in sql and "oa.location_id=:location" in sql:
            return _Result(scalar=1 if params.get("location") == self.location_id else None)
        if "FROM delegations d" in sql:
            return _Result(scalar=None)
        if "FROM locations" in sql:
            return _Result(scalars=self.owner_locations)
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
        "permissions": ["dataset.upload"] if "branch_head" in roles or "organization_owner" in roles else [],
    }


@pytest.mark.parametrize(
    "resource_grant",
    [None, [], ["dataset.view_original"], ["dataset.upload"], ["dataset.upload_original"]],
)
def test_manager_cannot_replace_original_without_branch_upload_grant(monkeypatch, resource_grant):
    # Per-dataset read/copy/resource grants are not a substitute for the
    # Owner/Branch-Head-issued branch upload grant.
    db = _Db(
        ["manager"], grant=resource_grant, manager_locations=["branch-1"],
        manager_upload_grants=[],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="explicit upload grant"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1", "dataset-1", "dataset.upload",
        )


def test_manager_with_explicit_branch_upload_grant_can_replace_original(monkeypatch):
    db = _Db(
        ["manager"], manager_locations=["branch-1"],
        manager_upload_grants=["branch-1"],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider, "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )
    result = supabase_provider.authorize_dataset(
        {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
        "workspace-1", "dataset-1", "dataset.upload",
    )
    assert result["authorized"] is True
    assert result["location_id"] == "branch-1"


def test_manager_upload_grant_cannot_authorize_another_branch(monkeypatch):
    db = _Db(
        ["manager"], manager_locations=["branch-a"],
        location_id="branch-b", manager_upload_grants=["branch-a"],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider, "authorization_context",
        lambda claims, workspace_id: _context(["manager"]),
    )
    with pytest.raises(supabase_provider.AuthzError, match="no active upload grant"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1", "dataset-1", "dataset.upload",
        )

def test_manager_cannot_upload_ordinary_dataset_without_replacement_grant(monkeypatch):
    db = _Db(["manager"], manager_locations=["branch-1"], protected=False)
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: _context(["manager"]))
    with pytest.raises(supabase_provider.AuthzError, match="Only the active Branch Head"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1", "dataset-ordinary", "dataset.upload",
        )

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

    with pytest.raises(supabase_provider.AuthzError, match="Only the active Branch Head"):
        supabase_provider.authorize_dataset(
            {"uid": "manager-1", "sub": "manager-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.upload",
        )


def test_organization_owner_can_write_original_dataset(monkeypatch):
    db = _Db(["organization_owner"], owner_locations=["branch-1"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider, "authorization_context",
        lambda claims, workspace_id: {
            **_context(["organization_owner"]),
            "permissions": ["dataset.upload", "dataset.manage_acl"],
        },
    )
    result = supabase_provider.authorize_dataset(
        {"uid": "owner-1", "sub": "owner-1", "provider": "supabase"},
        "workspace-1", "dataset-1", "dataset.upload",
    )
    assert result["authorized"] is True
    assert result["location_id"] == "branch-1"

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

    with pytest.raises(supabase_provider.AuthzError, match="Only the active Branch Head"):
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
            return _Result(row={
                "location_id": "branch-1",
                "protected_original": True,
                "status": "active",
            })
        if "FROM identity_bindings b" in sql and "JOIN organization_members m" in sql:
            return _Result(scalar=self.target_principal)
        if "SELECT resource_type FROM authorization_resources" in sql:
            return _Result(row={"resource_type": "dataset"})
        if "FROM organizational_assignments oa" in sql and "oa.role_id='manager'" in sql:
            return _Result(scalar=1 if self.target_manager_active else None)
        if "FROM organizational_assignments oa" in sql and "role_id='branch_head'" in sql:
            return _Result(scalars=[self.actor_location] if self.actor_location else [])
        if "FROM organizational_assignments oa" in sql and "mr.role_id=oa.role_id" in sql:
            principal = str(params.get("principal") or "")
            if principal == self.target_principal and self.target_manager_active:
                return _Result(scalars=[{
                    "assignment_id": "assignment-manager",
                    "location_id": "branch-1",
                    "section_id": None,
                    "role_id": "manager",
                }])
            return _Result(scalars=[])
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


def test_branch_head_cannot_delegate_original_write_authority(monkeypatch):
    db = _GrantDb()
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)
    with pytest.raises(ValueError, match="Only dataset.create_working_copy"):
        supabase_provider.set_dataset_grant(
            {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
            "workspace-1", "dataset-1", "manager-uid", ["dataset.upload_original"],
        )

def test_branch_head_cannot_delegate_original_write_to_other_branch_manager(monkeypatch):
    db = _GrantDb(target_manager_active=False)
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)
    with pytest.raises(ValueError, match="Only dataset.create_working_copy"):
        supabase_provider.set_dataset_grant(
            {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
            "workspace-1", "dataset-1", "manager-uid", ["dataset.upload_original"],
        )

def test_manager_cannot_issue_protected_replacement_grants(monkeypatch):
    db = _GrantDb(target_principal="manager-principal")
    context = _grantor_context("manager")
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)
    with pytest.raises(ValueError, match="Only dataset.create_working_copy"):
        supabase_provider.set_dataset_grant(
            {"uid": "manager-uid", "sub": "manager-uid", "provider": "supabase"},
            "workspace-1", "dataset-1", "manager-uid", ["dataset.upload_original"],
        )

def test_branch_head_cannot_grant_protected_replacement_to_self(monkeypatch):
    db = _GrantDb(target_principal="head-principal")
    context = _grantor_context()
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: context)
    with pytest.raises(ValueError, match="Only dataset.create_working_copy"):
        supabase_provider.set_dataset_grant(
            {"uid": "head-uid", "sub": "head-uid", "provider": "supabase"},
            "workspace-1", "dataset-1", "head-uid", ["dataset.upload_original"],
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


def test_branch_head_cannot_create_working_copy_from_another_branch(monkeypatch):
    db = _Db(
        ["branch_head"],
        grant=None,
        branch_locations=["branch-b"],
        location_id="branch-a",
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["branch_head"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="outside your Branch Head scope"):
        supabase_provider.authorize_dataset(
            {"uid": "head-1", "sub": "head-1", "provider": "supabase"},
            "workspace-1",
            "dataset-from-branch-a",
            "dataset.create_working_copy",
        )


def test_external_viewer_cannot_create_working_copy_even_with_resource_grant(monkeypatch):
    db = _Db(["external_viewer"], grant=["dataset.create_working_copy"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["external_viewer"]),
    )

    with pytest.raises(supabase_provider.AuthzError, match="read-only"):
        supabase_provider.authorize_dataset(
            {"uid": "viewer-1", "sub": "viewer-1", "provider": "supabase"},
            "workspace-1",
            "dataset-1",
            "dataset.create_working_copy",
        )


def test_external_viewer_can_read_only_an_explicitly_shared_original(monkeypatch):
    db = _Db(["external_viewer"], grant=["dataset.view_original"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context(["external_viewer"]),
    )

    result = supabase_provider.authorize_dataset(
        {"uid": "viewer-1", "sub": "viewer-1", "provider": "supabase"},
        "workspace-1",
        "dataset-shared",
        "dataset.view_original",
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-1"


def test_inactive_external_viewer_cannot_use_stale_member_role_grant(monkeypatch):
    # The database test double still reports an old role row, but authorization_context
    # no longer includes External Viewer because its assignment is inactive or out of scope.
    db = _Db(["external_viewer"], grant=["dataset.view_original"])
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(db))
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: _context([]),
    )

    with pytest.raises(
        supabase_provider.AuthzError,
        match="Only a Manager, Branch Head, Organization Owner",
    ):
        supabase_provider.authorize_dataset(
            {"uid": "stale-viewer-1", "sub": "stale-viewer-1", "provider": "supabase"},
            "workspace-1",
            "dataset-stale-viewer",
            "dataset.view_original",
        )
