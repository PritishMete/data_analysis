import pytest

from dataset_storage import service
from dataset_storage.provider import FirebaseDatasetStorageProvider, StoredDatasetObject


def test_storage_paths_are_traversal_safe():
    provider = FirebaseDatasetStorageProvider(bucket=object())
    assert provider.object_path(
        workspace_id="org_1", dataset_id="ds_abc123", version_id="v1"
    ) == "organizations/org_1/datasets/ds_abc123/versions/v1/source"
    with pytest.raises(ValueError):
        provider.object_path(workspace_id="../org", dataset_id="ds_1", version_id="v1")


def test_managed_filename_is_csv_only():
    assert service._safe_filename("financial-risk.csv") == "financial-risk.csv"
    with pytest.raises(ValueError):
        service._safe_filename("financial-risk.xlsx")
    with pytest.raises(ValueError):
        service._safe_filename("../financial-risk.csv")


def test_storage_provider_can_still_store_original_binary_objects():
    class Blob:
        def __init__(self, name):
            self.name = name
            self.metadata = None

        def upload_from_string(self, data, content_type=None):
            self.data = data
            self.content_type = content_type

    class Bucket:
        def blob(self, name):
            self.blob_obj = Blob(name)
            return self.blob_obj

    bucket = Bucket()
    result = FirebaseDatasetStorageProvider(bucket=bucket).upload(
        workspace_id="org",
        dataset_id="ds_binary",
        version_id="v1",
        data=b"binary\x00\xff",
        original_filename="source.bin",
        content_type="application/octet-stream",
    )
    assert result.size == 8
    assert bucket.blob_obj.data == b"binary\x00\xff"


def test_employee_roles_do_not_receive_dataset_upload():
    from firebase_authz.schema import DEFAULT_ROLES

    for role in ("external_viewer", "employee", "team_lead"):
        assert "dataset.upload" not in DEFAULT_ROLES[role]


def test_no_public_download_url_is_returned():
    from dataset_storage.routes import router

    route = next(item for item in router.routes if item.path.endswith("/download"))
    assert route.path == "/v1/managed-datasets/{dataset_id}/download"
