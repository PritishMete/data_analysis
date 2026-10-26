import io

import pytest

from dataset_storage import service as dataset_service
from firebase_authz import supabase_provider


class _Result:
    def __init__(self, values=None):
        self.values = list(values or [])

    def scalars(self):
        return self

    def all(self):
        return self.values


class _AssignmentDb:
    def __init__(self, assignments, upload_permission_roles=None, manager_upload_grants=None):
        self.assignments = assignments
        self.manager_upload_grants = set(manager_upload_grants or [])
        self.upload_permission_roles = (
            set(assignments) if upload_permission_roles is None
            else set(upload_permission_roles)
        )

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        if "FROM manager_dataset_upload_grants g" in sql:
            return _Result(sorted(self.manager_upload_grants))
        assert "FROM organizational_assignments oa" in sql
        assert "JOIN locations l" in sql
        assert "JOIN organization_members m" in sql
        assert "JOIN member_roles mr" in sql
        assert "JOIN role_permissions rp" in sql
        role = (params or {}).get("role")
        if role not in self.upload_permission_roles:
            return _Result([])
        return _Result(self.assignments.get(role, []))


class _SessionFactory:
    def __init__(self, assignments, upload_permission_roles=None, manager_upload_grants=None):
        self.db = _AssignmentDb(assignments, upload_permission_roles, manager_upload_grants)

    def __call__(self):
        return self.db


def _context(role="manager", *, permission=True, authorized=True):
    return {
        "workspace_authorized": authorized,
        "workspace_id": "workspace-1",
        "organization_id": "org-1",
        "principal_id": "principal-1",
        "role_ids": [role],
        "permissions": ["dataset.upload"] if permission else [],
    }


def _install_scope(
    monkeypatch, role="manager", *, permission=True, authorized=True, assignments=None,
    upload_permission_roles=None, manager_upload_grants=None,
):
    context = _context(role, permission=permission, authorized=authorized)
    monkeypatch.setattr(
        supabase_provider, "authorization_context",
        lambda claims, workspace_id: context,
    )
    monkeypatch.setattr(
        supabase_provider, "SessionLocal",
        _SessionFactory(assignments or {}, upload_permission_roles, manager_upload_grants),
    )


def _claims():
    return {"uid": "principal-1", "sub": "principal-1", "provider": "supabase"}


def test_active_manager_with_explicit_branch_upload_grant_is_allowed(monkeypatch):
    _install_scope(
        monkeypatch, permission=False,
        assignments={"manager": ["branch-a"]},
        manager_upload_grants=["branch-a"],
    )

    result = supabase_provider.authorize_dataset_upload_scope(
        _claims(), "workspace-1"
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-a"
    assert result["upload_role_id"] == "manager"


def test_replaced_manager_with_stale_member_role_is_denied(monkeypatch):
    # The historical member_roles row still resolves to Manager, but replacement
    # has removed the active organizational assignment.
    _install_scope(monkeypatch, assignments={"manager": []})

    with pytest.raises(supabase_provider.AuthzError, match="active Manager assignment"):
        supabase_provider.authorize_dataset_upload_scope(_claims(), "workspace-1")


def test_replacement_manager_with_active_assignment_and_grant_is_allowed(monkeypatch):
    _install_scope(
        monkeypatch, permission=False,
        assignments={"manager": ["branch-a"]},
        manager_upload_grants=["branch-a"],
    )

    result = supabase_provider.authorize_dataset_upload_scope(
        _claims(), "workspace-1", location_id="branch-a"
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-a"


def test_manager_cannot_upload_to_another_branch(monkeypatch):
    _install_scope(
        monkeypatch, assignments={"manager": ["branch-a"]},
        manager_upload_grants=["branch-a"],
    )

    with pytest.raises(
        supabase_provider.AuthzError,
        match="no active upload grant",
    ):
        supabase_provider.authorize_dataset_upload_scope(
            _claims(), "workspace-1", location_id="branch-b"
        )


def test_manager_without_explicit_branch_upload_grant_is_denied(monkeypatch):
    _install_scope(
        monkeypatch, permission=False, assignments={"manager": ["branch-a"]},
        manager_upload_grants=[],
    )

    with pytest.raises(supabase_provider.AuthzError, match="explicit upload grant"):
        supabase_provider.authorize_dataset_upload_scope(_claims(), "workspace-1")


def test_stale_other_role_cannot_supply_manager_upload_permission(monkeypatch):
    # authorization_context aggregates capabilities across historical roles.
    # The active Manager assignment must separately possess dataset.upload.
    _install_scope(
        monkeypatch, permission=False,
        assignments={"manager": ["branch-a"]},
        upload_permission_roles=[],
        manager_upload_grants=[],
    )

    with pytest.raises(
        supabase_provider.AuthzError,
        match="explicit upload grant",
    ):
        supabase_provider.authorize_dataset_upload_scope(_claims(), "workspace-1")


def test_inactive_membership_is_denied_before_assignment_lookup(monkeypatch):
    _install_scope(
        monkeypatch, authorized=False,
        assignments={"manager": ["branch-a"]},
    )

    with pytest.raises(supabase_provider.AuthzError, match="Workspace authorization denied"):
        supabase_provider.authorize_dataset_upload_scope(_claims(), "workspace-1")


def test_missing_or_ambiguous_branch_assignment_fails_closed(monkeypatch):
    _install_scope(
        monkeypatch, permission=False,
        assignments={"manager": ["branch-a", "branch-b"]},
        manager_upload_grants=["branch-a", "branch-b"],
    )

    with pytest.raises(
        supabase_provider.AuthzError,
        match="unambiguous active branch assignment",
    ):
        supabase_provider.authorize_dataset_upload_scope(_claims(), "workspace-1")


def test_branch_head_requires_current_assignment_and_upload_permission(monkeypatch):
    _install_scope(
        monkeypatch, role="branch_head",
        assignments={"branch_head": ["branch-a"]},
    )

    result = supabase_provider.authorize_dataset_upload_scope(
        _claims(), "workspace-1"
    )

    assert result["authorized"] is True
    assert result["location_id"] == "branch-a"


def test_protected_original_upload_uses_upload_capability_before_registry(monkeypatch):
    context = _context("manager")
    seen = []

    def deny_protected_replacement(claims, workspace_id, target_id, action):
        seen.append(action)
        raise supabase_provider.AuthzError(
            "An explicit dataset.upload_original grant is required to replace this protected original."
        )

    monkeypatch.setattr(dataset_service, "_claims", lambda token: _claims())
    monkeypatch.setattr(dataset_service, "_authorize_dataset", deny_protected_replacement)

    def fail_if_registry_created(*args, **kwargs):
        raise AssertionError("Dataset registry must not be initialized for a denied upload.")

    monkeypatch.setattr(dataset_service, "DatasetRepository", fail_if_registry_created)
    stream = io.BytesIO(b"id,value\n1,private\n")

    with pytest.raises(supabase_provider.AuthzError, match="dataset.upload_original"):
        dataset_service.upload_managed_dataset_stream(
            workspace_id="workspace-1",
            token="unused-by-test",
            filename="data.csv",
            stream=stream,
            content_type="text/csv",
            dataset_id="protected-dataset",
        )

    assert seen == ["dataset.upload"]
    assert stream.tell() == 0


@pytest.mark.parametrize("dataset_id", [None, "existing-dataset"])
def test_denied_upload_never_reads_stream_or_initializes_registry(monkeypatch, dataset_id):
    context = _context("manager")
    monkeypatch.setattr(dataset_service, "_claims", lambda token: _claims())
    monkeypatch.setattr(
        dataset_service, "authorization_context",
        lambda claims, workspace_id: context,
    )
    monkeypatch.setattr(
        supabase_provider, "authorization_context",
        lambda claims, workspace_id: context,
    )
    monkeypatch.setattr(
        dataset_service, "_authorize_dataset",
        lambda claims, workspace_id, target_id, action: {
            "authorized": True, "location_id": "branch-a"
        },
    )
    monkeypatch.setattr(
        supabase_provider, "SessionLocal",
        _SessionFactory({"manager": []}),
    )

    def fail_if_registry_created(*args, **kwargs):
        raise AssertionError("Dataset registry must not be initialized for a denied upload.")

    monkeypatch.setattr(dataset_service, "DatasetRepository", fail_if_registry_created)
    stream = io.BytesIO(b"id,value\n1,private\n")

    with pytest.raises(supabase_provider.AuthzError, match="Branch Head only"):
        dataset_service.upload_managed_dataset_stream(
            workspace_id="workspace-1",
            token="unused-by-test",
            filename="data.csv",
            stream=stream,
            content_type="text/csv",
            dataset_id=dataset_id,
        )

    assert stream.tell() == 0
