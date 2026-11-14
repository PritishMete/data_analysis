from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

import core.db
import dataset_storage.service as managed_service


@dataclass
class FakeDataset:
    dataset_id: str
    status: str = "ready"
    dataset_name: str | None = None
    original_filename: str | None = None
    created_at: datetime | None = None


class FakeRepository:
    def __init__(self, datasets):
        self.datasets = datasets
        self.db = self
        self.closed = False

    def list_by_organization(self, organization_id, limit=50, offset=0, location_ids=None):
        # These catalogue unit fixtures model a single authorized branch; the
        # production repository applies location_ids in SQL before pagination.
        return self.datasets[offset : offset + limit]

    def list_versions(self, dataset_id):
        return []

    def close(self):
        self.closed = True


def _setup_catalogue(monkeypatch, datasets, *, roles=None, denied_ids=None):
    repo = FakeRepository(datasets)
    monkeypatch.setattr(core.db, "SessionLocal", lambda: repo)
    monkeypatch.setattr(managed_service, "DatasetRepository", lambda _db: repo)
    monkeypatch.setattr(managed_service, "_claims", lambda _token: {"sub": "test-user"})
    monkeypatch.setattr(
        managed_service,
        "_authorization_context",
        lambda _claims, _workspace: {
            "organization_id": "org-test",
            "role_ids": roles or ["organization_owner"],
        },
    )
    monkeypatch.setattr(
        managed_service, "_recover_stale_processing_uploads", lambda *_args: None
    )

    denied = set(denied_ids or [])

    def authorize(_claims, _workspace, dataset_id, _action):
        if dataset_id in denied:
            raise managed_service.AuthzError("not authorized")
        return {"location_id": "branch-test", "location_name": "Test Branch"}

    monkeypatch.setattr(managed_service, "_authorize_dataset", authorize)
    monkeypatch.setattr(
        managed_service,
        "_structured_summary",
        lambda dataset, version_count: {
            "dataset_id": dataset.dataset_id,
            "dataset_name": dataset.dataset_name or dataset.dataset_id,
            "display_name": dataset.dataset_name or dataset.dataset_id,
            "status": dataset.status,
            "created_at": (
                dataset.created_at.isoformat() if dataset.created_at else None
            ),
            "version_count": version_count,
        },
    )
    return repo


def test_catalogue_paginates_past_first_hundred_authorized_datasets(monkeypatch):
    now = datetime.now(timezone.utc)
    datasets = [
        FakeDataset(
            dataset_id=f"dataset-{index:03d}",
            dataset_name=f"Dataset {index:03d}",
            created_at=now,
        )
        for index in range(251)
    ]
    repo = _setup_catalogue(monkeypatch, datasets)

    first = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=0
    )
    last = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=200
    )

    assert first["pagination"] == {
        "offset": 0,
        "limit": 100,
        "total": 251,
        "has_more": True,
    }
    assert len(first["datasets"]) == 100
    assert len(last["datasets"]) == 51
    assert last["pagination"]["has_more"] is False
    assert last["datasets"][0]["dataset_id"] == "dataset-200"
    assert last["datasets"][-1]["dataset_id"] == "dataset-250"
    assert repo.closed


def test_catalogue_total_counts_only_authorized_datasets(monkeypatch):
    datasets = [
        FakeDataset(dataset_id=f"dataset-{index}", created_at=datetime.now(timezone.utc))
        for index in range(5)
    ]
    _setup_catalogue(monkeypatch, datasets, denied_ids={"dataset-1", "dataset-3"})

    result = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=0
    )

    ids = [item["dataset_id"] for item in result["datasets"]]
    assert ids == ["dataset-0", "dataset-2", "dataset-4"]
    assert result["pagination"]["total"] == 3
    assert result["pagination"]["has_more"] is False


def test_failed_dataset_status_is_visible_only_to_privileged_catalogue(monkeypatch):
    datasets = [
        FakeDataset(dataset_id="ready-dataset", status="ready"),
        FakeDataset(dataset_id="failed-dataset", status="failed"),
    ]
    _setup_catalogue(monkeypatch, datasets, roles=["organization_owner"])

    privileged = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=0
    )
    assert [item["status"] for item in privileged["datasets"]] == ["ready", "failed"]

    _setup_catalogue(monkeypatch, datasets, roles=["employee"])
    copy_only = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=0
    )
    assert [item["dataset_id"] for item in copy_only["datasets"]] == ["ready-dataset"]



def test_copy_only_catalogue_includes_safe_status_and_branch_metadata(monkeypatch):
    dataset = FakeDataset(
        dataset_id="copy-source",
        status="ready",
        dataset_name="Authorized source",
        created_at=datetime.now(timezone.utc),
    )
    _setup_catalogue(monkeypatch, [dataset], roles=["employee"])

    result = managed_service.list_authorized_datasets(
        workspace_id="workspace-test", token="test-token", limit=100, offset=0
    )

    item = result["datasets"][0]
    assert item["status"] == "ready"
    assert item["location_id"] == "branch-test"
    assert item["location_name"] == "Test Branch"
    assert item["created_at"] == dataset.created_at.isoformat()
    assert "current_version" not in item
    assert "version_count" not in item
