import pytest

from dataset_storage import manager_grants


class _Rows:
    def mappings(self):
        return self

    def all(self):
        return [{"location_id": "branch-a", "location_name": "Branch A"}]


class _Session:
    def __init__(self):
        self.statement = ""

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, statement, params=None):
        self.statement = str(statement)
        return _Rows()


@pytest.mark.parametrize("role", ["branch_head", "manager"])
def test_distinct_upload_scope_query_uses_selected_ordering_columns(monkeypatch, role):
    context = {
        "workspace_authorized": True,
        "workspace_id": "workspace-1",
        "organization_id": "org-1",
        "principal_id": "principal-1",
        "role_ids": [role],
    }
    session = _Session()
    monkeypatch.setattr(manager_grants, "_claims", lambda token: {"uid": "principal-1"})
    monkeypatch.setattr(
        manager_grants,
        "_authorization_context",
        lambda claims, workspace_id: context,
    )
    monkeypatch.setattr(manager_grants, "SessionLocal", lambda: session)

    locations = manager_grants.list_uploadable_locations(
        workspace_id="workspace-1",
        token="test-token",
    )

    assert locations == [{"location_id": "branch-a", "location_name": "Branch A"}]
    assert "SELECT DISTINCT l.location_id, l.name AS location_name" in session.statement
    assert "ORDER BY l.name, l.location_id" in session.statement
    assert "ORDER BY lower(l.name)" not in session.statement
