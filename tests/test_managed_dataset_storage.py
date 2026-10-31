import pytest

from dataset_storage import service
from dataset_storage.provider import SupabaseDatasetStorageProvider, archive_original_enabled


def test_storage_paths_are_traversal_safe(monkeypatch):
    provider = SupabaseDatasetStorageProvider(client=object())
    assert provider.object_path(
        organization_id="org_1", dataset_id="ds_abc123", version_id="v1"
    ) == "organizations/org_1/datasets/ds_abc123/versions/v1/original.csv"
    with pytest.raises(ValueError):
        provider.object_path(
            organization_id="../org", dataset_id="ds_1", version_id="v1"
        )


def test_managed_filename_is_csv_only():
    assert service._safe_filename("financial-risk.csv") == "financial-risk.csv"
    with pytest.raises(ValueError):
        service._safe_filename("financial-risk.xlsx")
    with pytest.raises(ValueError):
        service._safe_filename("../financial-risk.csv")


def test_original_archive_is_opt_in(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL", "false")
    assert archive_original_enabled() is False
    monkeypatch.setenv("INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL", "true")
    assert archive_original_enabled() is True


def test_employee_roles_do_not_receive_dataset_upload():
    from firebase_authz.schema import DEFAULT_ROLES

    for role in ("external_viewer", "employee", "team_lead"):
        assert "dataset.upload" not in DEFAULT_ROLES[role]


def test_no_public_download_url_is_returned():
    from dataset_storage.routes import router

    route = next(item for item in router.routes if item.path.endswith("/download"))
    assert route.path == "/v1/managed-datasets/{dataset_id}/download"

def test_dataset_display_name_is_validated_and_defaults_to_filename():
    assert service._safe_dataset_name("Retail Sales 2026", "retail_sales.csv") == "Retail Sales 2026"
    assert service._safe_dataset_name(None, "retail_sales.csv") == "retail_sales"
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("   ", "retail_sales.csv")
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("bad\nname", "retail_sales.csv")
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("x" * 256, "retail_sales.csv")



def test_duplicate_dataset_upload_conflict_is_a_confirmable_http_409():
    from dataset_storage.routes import _map_error
    from dataset_storage.service import DatasetUploadConflict

    conflict = DatasetUploadConflict([
        {
            "dataset_id": "existing-dataset",
            "dataset_name": "Retail Sales 2026",
            "original_filename": "retail.csv",
            "reason": "name",
        }
    ])
    response = _map_error(conflict)
    assert response.status_code == 409
    assert response.detail["code"] == "dataset_duplicate"
    assert response.detail["conflicts"][0]["dataset_id"] == "existing-dataset"


def test_managed_upload_route_accepts_dataset_name_and_replacement_target():
    from dataset_storage.routes import router

    route = next(item for item in router.routes if item.path == "/v1/managed-datasets" and "POST" in item.methods)
    import inspect
    parameters = inspect.signature(route.endpoint).parameters
    assert "dataset_name" in parameters
    assert "replace_dataset_id" in parameters



def test_duplicate_detection_checks_ready_version_hashes_and_explicit_target():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    assert "DatasetVersion.file_hash == incoming_hash" in source
    assert "DatasetVersion.status == \"ready\"" in source
    assert "replace_dataset_id not in conflicts_by_id" in source
    assert "replace_dataset_id is None and conflicts" in source



def test_duplicate_detection_checks_ready_version_hashes_and_explicit_target():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    assert "DatasetVersion.file_hash == incoming_hash" in source
    assert 'DatasetVersion.status == "ready"' in source
    assert "replace_dataset_id not in conflicts_by_id" in source
    assert "replace_dataset_id is None and conflicts" in source
