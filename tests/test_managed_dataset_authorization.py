import pytest

from dataset_storage import service as dataset_service
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


class _AuthzSession:
    def __init__(self, *, resource=None, protected=True, grant=None, owner="principal-owner"):
        self.resource = resource
        self.protected = protected
        self.grant = grant
        self.owner = owner
        self.calls = []

    def execute(self, statement, params=None):
        sql = str(statement)
        self.calls.append((sql, params or {}))
        if "FROM authorization_resources" in sql and "SELECT resource_type" in sql:
            return _Result(row=self.resource)
        if "FROM authorization_resources" in sql and "SELECT 1" in sql:
            return _Result(scalar=1 if self.resource else None)
        if "FROM dataset_authorization" in sql:
            return _Result(scalar=self.protected)
        if "FROM resource_grants" in sql:
            return _Result(scalar=self.grant)
        if "FROM identity_bindings" in sql and "JOIN organization_members" in sql:
            return _Result(scalar=self.owner)
        return _Result()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def begin(self):
        return self


class _SessionFactory:
    def __init__(self, session):
        self.session = session

    def __call__(self):
        return self.session

    def begin(self):
        return self.session


def _context():
    return {
        "membership_status": "active",
        "workspace_authorized": True,
        "authorization_state": "active_identity",
        "principal_id": "principal-owner",
        "organization_id": "org-owner",
        "workspace_id": "workspace-owner",
        "role_ids": ["organization_owner"],
        "permissions": [
            "dataset.view_original",
            "dataset.create_working_copy",
            "dataset.manage_acl",
        ],
    }


def test_owner_dataset_authorization_uses_resolved_organization_and_grant(monkeypatch):
    session = _AuthzSession(
        resource={"resource_type": "dataset", "owner_principal_id": "principal-owner"},
        protected=True,
        grant=[
            "dataset.view_original",
            "dataset.create_working_copy",
            "dataset.manage_acl",
        ],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(session))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: _context())

    result = supabase_provider.authorize_dataset(
        {"uid": "owner", "sub": "owner", "provider": "supabase"},
        "workspace-owner",
        "dataset-owner",
        "dataset.view_original",
    )

    assert result["authorized"] is True
    assert result["organization_id"] == "org-owner"
    assert result["workspace_id"] == "workspace-owner"
    resource_query = next(params for sql, params in session.calls if "FROM authorization_resources" in sql and "SELECT resource_type" in sql)
    grant_query = next(params for sql, params in session.calls if "FROM resource_grants" in sql)
    assert resource_query["org"] == "org-owner"
    assert grant_query["org"] == "org-owner"


def test_dataset_from_wrong_organization_is_rejected(monkeypatch):
    session = _AuthzSession(resource=None, protected=None, grant=None)
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(session))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: _context())

    with pytest.raises(supabase_provider.AuthzError, match="Resource is not accessible"):
        supabase_provider.authorize_dataset(
            {"uid": "owner", "sub": "owner", "provider": "supabase"},
            "workspace-owner",
            "dataset-from-org-b",
            "dataset.view_original",
        )

    resource_query = next(params for sql, params in session.calls if "FROM authorization_resources" in sql and "SELECT resource_type" in sql)
    assert resource_query["org"] == "org-owner"


def test_revoked_dataset_grant_is_rejected(monkeypatch):
    session = _AuthzSession(
        resource={"resource_type": "dataset", "owner_principal_id": "principal-owner"},
        protected=True,
        grant=[],
    )
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(session))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: _context())

    with pytest.raises(supabase_provider.AuthzError, match="Permission denied for this resource"):
        supabase_provider.authorize_dataset(
            {"uid": "owner", "sub": "owner", "provider": "supabase"},
            "workspace-owner",
            "dataset-owner",
            "dataset.view_original",
        )


def test_register_dataset_stores_resource_under_resolved_organization(monkeypatch):
    session = _AuthzSession(owner="principal-owner")
    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory(session))
    monkeypatch.setattr(supabase_provider, "authorization_context", lambda claims, workspace_id: _context())

    result = supabase_provider.register_dataset(
        {"uid": "owner", "sub": "owner", "provider": "supabase"},
        "workspace-owner",
        "dataset-owner",
        "owner",
    )

    assert result["organization_id"] == "org-owner"
    assert result["workspace_id"] == "workspace-owner"
    inserts = [(sql, params) for sql, params in session.calls if "INSERT INTO authorization_resources" in sql or "INSERT INTO dataset_authorization" in sql or "INSERT INTO resource_grants" in sql]
    assert inserts
    assert all(params["org"] == "org-owner" for _, params in inserts)


def test_owner_rows_preview_returns_first_100_of_100000_after_authorization(monkeypatch):
    rows = [
        {"row_number": i + 1, "row_data": {"id": i + 1, "name": f"customer-{i + 1}"}}
        for i in range(100)
    ]

    class Dataset:
        organization_id = "org-owner"
        dataset_id = "dataset-owner"

    class Version:
        version_id = "v1"
        version_pk = "version-pk"
        status = "ready"
        row_count = 100000
        column_count = 2

    class Repo:
        def __init__(self, db):
            pass

        def get_by_id(self, dataset_id):
            assert dataset_id == "dataset-owner"
            return Dataset()

        def get_version(self, dataset_id, version_id):
            assert dataset_id == "dataset-owner"
            assert version_id == "v1"
            return Version()

        def get_rows(self, version_pk, limit, offset):
            assert version_pk == "version-pk"
            assert limit == 100
            assert offset == 0
            return rows

        def close(self):
            pass

        db = None

    monkeypatch.setattr(dataset_service, "DatasetRepository", Repo)
    monkeypatch.setattr(dataset_service, "_claims", lambda token: {"uid": "owner", "sub": "owner", "provider": "supabase"})
    monkeypatch.setattr(dataset_service, "_authorization_context", lambda claims, workspace_id: _context())
    monkeypatch.setattr(
        dataset_service,
        "_authorize_dataset",
        lambda claims, workspace_id, dataset_id, action: {
            "authorized": True,
            "organization_id": "org-owner",
            "workspace_id": "workspace-owner",
            "dataset_id": dataset_id,
        },
    )

    class _DbFactory:
        def __call__(self):
            return self

        def close(self):
            pass

    monkeypatch.setattr("core.db.SessionLocal", _DbFactory())

    result = dataset_service.get_managed_dataset_rows(
        workspace_id="workspace-owner",
        token="token",
        dataset_id="dataset-owner",
        version_id="v1",
        limit=100,
        offset=0,
    )

    assert result["row_count"] == 100000
    assert result["column_count"] == 2
    assert result["offset"] == 0
    assert result["limit"] == 100
    assert len(result["rows"]) == 100
    assert result["rows"][0]["row_data"]["id"] == 1
    assert result["rows"][-1]["row_data"]["id"] == 100
