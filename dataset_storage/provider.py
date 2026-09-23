from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class StoredDatasetObject:
    storage_object_id: str
    size: int
    content_type: str | None = None
    checksum: str | None = None


class DatasetStorageProvider(ABC):
    """Binary storage contract. Authorization is deliberately outside this interface."""

    @abstractmethod
    def upload(self, *, workspace_id: str, dataset_id: str, version_id: str, data: bytes,
               original_filename: str, content_type: str | None) -> StoredDatasetObject: ...

    @abstractmethod
    def download(self, *, workspace_id: str, dataset_id: str, version_id: str) -> bytes: ...

    @abstractmethod
    def delete(self, *, workspace_id: str, dataset_id: str, version_id: str) -> None: ...

    @abstractmethod
    def exists(self, *, workspace_id: str, dataset_id: str, version_id: str) -> bool: ...

    @abstractmethod
    def create_working_copy_object(self, *, workspace_id: str, dataset_id: str,
                                   version_id: str, working_copy_id: str) -> StoredDatasetObject: ...

    @abstractmethod
    def get_object_metadata(self, *, workspace_id: str, dataset_id: str,
                            version_id: str) -> dict[str, Any]: ...


class FirebaseDatasetStorageProvider(DatasetStorageProvider):
    """Current TEST provider. Uses Firebase Admin SDK / Google Cloud Storage."""

    def __init__(self, bucket=None):
        self._bucket_override = bucket

    @staticmethod
    def _component(value: str, field: str) -> str:
        import re
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}", value):
            raise ValueError(f"Invalid {field}.")
        return value

    def _bucket(self):
        if self._bucket_override is not None:
            return self._bucket_override
        from firebase_admin import storage
        from firebase_authz.service import initialize_firebase
        initialize_firebase()
        import os
        bucket_name = os.environ.get("FIREBASE_STORAGE_BUCKET", "").strip()
        if not bucket_name:
            raise RuntimeError("Firebase Storage is not configured: FIREBASE_STORAGE_BUCKET is required.")
        return storage.bucket(bucket_name)

    def object_path(self, *, workspace_id: str, dataset_id: str, version_id: str) -> str:
        return "organizations/{}/datasets/{}/versions/{}/source".format(
            self._component(workspace_id, "workspace ID"),
            self._component(dataset_id, "dataset ID"),
            self._component(version_id, "version ID"),
        )

    def working_copy_path(self, *, workspace_id: str, dataset_id: str, working_copy_id: str) -> str:
        return "organizations/{}/datasets/{}/working-copies/{}/source".format(
            self._component(workspace_id, "workspace ID"),
            self._component(dataset_id, "dataset ID"),
            self._component(working_copy_id, "working copy ID"),
        )

    def upload(self, *, workspace_id: str, dataset_id: str, version_id: str, data: bytes,
               original_filename: str, content_type: str | None) -> StoredDatasetObject:
        import hashlib
        path = self.object_path(workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id)
        blob = self._bucket().blob(path)
        blob.metadata = {
            "dataset_id": dataset_id,
            "version_id": version_id,
            "original_filename": original_filename,
        }
        blob.upload_from_string(data, content_type=content_type or "application/octet-stream")
        return StoredDatasetObject(path, len(data), content_type, hashlib.sha256(data).hexdigest())

    def download(self, *, workspace_id: str, dataset_id: str, version_id: str) -> bytes:
        blob = self._bucket().blob(self.object_path(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        ))
        if not blob.exists():
            raise FileNotFoundError("Dataset object not found.")
        return blob.download_as_bytes()

    def delete(self, *, workspace_id: str, dataset_id: str, version_id: str) -> None:
        blob = self._bucket().blob(self.object_path(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        ))
        if blob.exists():
            blob.delete()

    def exists(self, *, workspace_id: str, dataset_id: str, version_id: str) -> bool:
        return self._bucket().blob(self.object_path(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        )).exists()

    def create_working_copy_object(self, *, workspace_id: str, dataset_id: str,
                                   version_id: str, working_copy_id: str) -> StoredDatasetObject:
        bucket = self._bucket()
        source = bucket.blob(self.object_path(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        ))
        if not source.exists():
            raise FileNotFoundError("Source dataset object not found.")
        path = self.working_copy_path(
            workspace_id=workspace_id, dataset_id=dataset_id, working_copy_id=working_copy_id
        )
        target = bucket.blob(path)
        source.bucket.copy_blob(source, target.bucket, target.name)
        target.reload()
        return StoredDatasetObject(
            path, int(target.size or 0), target.content_type, target.md5_hash
        )

    def get_object_metadata(self, *, workspace_id: str, dataset_id: str,
                            version_id: str) -> dict[str, Any]:
        blob = self._bucket().blob(self.object_path(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        ))
        if not blob.exists():
            raise FileNotFoundError("Dataset object not found.")
        blob.reload()
        return {
            "storage_object_id": blob.name,
            "size": int(blob.size or 0),
            "content_type": blob.content_type,
            "etag": blob.etag,
        }
