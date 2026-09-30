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
