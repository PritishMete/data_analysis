from types import SimpleNamespace

import pytest

from datasets.service import DatasetRegistryService


class _Session:
    def __init__(self):
        self.commits = 0
        self.rollbacks = 0
        self.flushes = 0

    def flush(self):
        self.flushes += 1

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1


class _Repository:
    def __init__(self, dataset, version):
        self.db = _Session()
        self.dataset = dataset
        self.version = version

    def get_by_id(self, dataset_id):
        return self.dataset if dataset_id == self.dataset.dataset_id else None

    def get_version(self, dataset_id, version_id):
        if dataset_id == self.dataset.dataset_id and version_id == self.version.version_id:
            return self.version
        return None


def _registry():
    dataset = SimpleNamespace(
        dataset_id="ds-1", status="ready", current_version_id="v1",
        version_number=1, schema_hash="old-schema", file_hash="old-hash",
        row_count=1, column_count=1, original_filename="old.csv",
        content_type="text/csv", file_size=10, storage_provider=None,
        storage_object_id=None, last_accessed=None,
    )
    version = SimpleNamespace(
        version_id="v2", status="processing", version_number=2,
        schema_hash="new-schema", file_hash="new-hash", row_count=2,
        column_count=1, original_filename="new.csv", content_type="text/csv",
        file_size=20, storage_provider=None, storage_object_id=None,
    )
    repo = _Repository(dataset, version)
    return DatasetRegistryService(repo), repo, dataset, version


def test_finalize_version_can_join_caller_owned_transaction():
    service, repo, dataset, version = _registry()

    result = service.finalize_version(
        "ds-1", "v2", expected_current_version_id="v1", commit=False
    )

    assert result is dataset
    assert dataset.current_version_id == "v2"
    assert version.status == "ready"
    assert repo.db.flushes == 1
    assert repo.db.commits == 0
    assert repo.db.rollbacks == 0


def test_finalize_version_rejects_stale_base_without_publishing():
    service, repo, dataset, version = _registry()
    dataset.current_version_id = "v3"

    with pytest.raises(ValueError, match="changed after this proposal"):
        service.finalize_version(
            "ds-1", "v2", expected_current_version_id="v1", commit=False
        )

    assert dataset.current_version_id == "v3"
    assert version.status == "processing"
    assert repo.db.commits == 0
    assert repo.db.rollbacks == 0


def test_default_finalize_version_retains_legacy_commit_behavior():
    service, repo, dataset, version = _registry()

    service.finalize_version("ds-1", "v2")

    assert repo.db.commits == 1
    assert repo.db.rollbacks == 0
    assert dataset.current_version_id == "v2"
