import pytest

from dataset_storage.provider import FirebaseDatasetStorageProvider, StoredDatasetObject
from dataset_storage import service


def test_storage_paths_are_opaque_and_traversal_safe():
    provider = FirebaseDatasetStorageProvider(bucket=object())
    assert provider.object_path(workspace_id="org_1", dataset_id="ds_abc123", version_id="v1") == "organizations/org_1/datasets/ds_abc123/versions/v1/source"
    with pytest.raises(ValueError):
        provider.object_path(workspace_id="../org", dataset_id="ds_1", version_id="v1")


def test_storage_treats_arbitrary_binary_as_an_object():
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
        workspace_id="org", dataset_id="ds_binary", version_id="v1",
        data=b"binary\x00\xff", original_filename="Customers.parquet",
        content_type="application/octet-stream",
    )
    assert result.size == 8
    assert bucket.blob_obj.data == b"binary\x00\xff"


def test_employee_upload_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_claims", lambda token: {"uid": "employee", "email_verified": True})
    monkeypatch.setattr(service, "authorization", lambda *args, **kwargs: (_ for _ in ()).throw(service.PermissionDenied("denied")))
    with pytest.raises(service.PermissionDenied):
        service.upload_managed_dataset(
            workspace_id="org", token="token", filename="Sales.xlsx", data=b"PK",
            content_type="application/octet-stream", provider=object(),
        )


def test_upload_generates_opaque_id_and_stores_metadata_only(monkeypatch):
    workspace = {"members": {"manager": {"status": "active", "roles": {"manager": True}}}, "datasets": {}}
    monkeypatch.setattr(service, "_claims", lambda token: {"uid": "manager", "email_verified": True})
    monkeypatch.setattr(service, "authorization", lambda *args, **kwargs: {"allowed": True})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    captured = {}
    class Ref:
        def set(self, value): captured.update(value)
        def update(self, value): captured.update(value)
    class DB:
        @staticmethod
        def reference(path): return Ref()
    monkeypatch.setattr(service, "db", DB(), raising=False)
    from firebase_admin import db as firebase_db
    monkeypatch.setattr(firebase_db, "reference", lambda path: Ref())
    class Provider:
        def upload(self, **kwargs):
            return StoredDatasetObject("organizations/org/datasets/ds_x/versions/v1/source", len(kwargs["data"]), kwargs["content_type"], "checksum")
    result = service.upload_managed_dataset(
        workspace_id="org", token="token", filename="Sales.xlsx", data=b"PK",
        content_type="application/octet-stream", provider=Provider(),
    )
    assert result["dataset_id"].startswith("ds_")
    assert result["organization_id"] == "org"
    assert "rows" not in captured and "cell_values" not in captured


def test_new_version_does_not_overwrite_v1(monkeypatch):
    workspace = {"members": {"manager": {"status": "active", "roles": {"manager": True}}},
        "datasets": {"ds_1": {"dataset_id": "ds_1", "owner_uid": "manager", "protected_original": True,
        "status": "active", "version": 1, "current_version": "v1",
        "versions": {"v1": {"storage_object_id": "old/source"}},
        "grants": {"manager": {"permissions": ["dataset.view_original", "dataset.create_working_copy", "dataset.manage_acl"]}}}}}
    monkeypatch.setattr(service, "_claims", lambda token: {"uid": "manager", "email_verified": True})
    monkeypatch.setattr(service, "authorization", lambda *args, **kwargs: {"allowed": True})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    captured = {}
    class Ref:
        def update(self, value): captured.update(value)
    class DB:
        @staticmethod
        def reference(path): return Ref()
    monkeypatch.setattr(service, "db", DB(), raising=False)
    from firebase_admin import db as firebase_db
    monkeypatch.setattr(firebase_db, "reference", lambda path: Ref())
    class Provider:
        def upload(self, **kwargs): return StoredDatasetObject("new/source", len(kwargs["data"]), "application/octet-stream", "new")
    result = service.upload_managed_dataset(
        workspace_id="org", token="token", filename="Sales-v2.xlsx", data=b"new",
        content_type="application/octet-stream", provider=Provider(), dataset_id="ds_1",
    )
    assert result["current_version"] == "v2"
    assert captured["versions/v2"]["storage_object_id"] == "new/source"
    assert "v1" in workspace["datasets"]["ds_1"]["versions"]


def test_external_viewer_employee_and_team_lead_cannot_upload():
    from firebase_authz.schema import DEFAULT_ROLES
    for role in ("external_viewer", "employee", "team_lead"):
        assert "dataset.upload" not in DEFAULT_ROLES[role]


def test_no_public_download_url_is_returned():
    from dataset_storage.routes import router
    route = next(item for item in router.routes if item.path.endswith("/download"))
    assert route.path == "/v1/managed-datasets/{dataset_id}/download"
