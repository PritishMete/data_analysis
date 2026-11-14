from __future__ import annotations

import hashlib
import os
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, BinaryIO


@dataclass(frozen=True)
class StoredDatasetObject:
    storage_object_id: str
    size: int
    content_type: str | None = None
    checksum: str | None = None


class DatasetStorageProvider(ABC):
    """Optional original-file archive. Analytical data never depends on this store."""

    @abstractmethod
    def upload_stream(
        self, *, organization_id: str, dataset_id: str, version_id: str,
        stream: BinaryIO, original_filename: str, content_type: str | None,
    ) -> StoredDatasetObject: ...

    @abstractmethod
    def download(self, *, organization_id: str, dataset_id: str, version_id: str) -> bytes: ...

    @abstractmethod
    def delete(self, *, organization_id: str, dataset_id: str, version_id: str) -> None: ...

    @abstractmethod
    def exists(self, *, organization_id: str, dataset_id: str, version_id: str) -> bool: ...


class SupabaseDatasetStorageProvider(DatasetStorageProvider):
    """Private Supabase Storage archive used only when original-file retention is enabled.

    The backend uses a server-only Supabase secret. Flutter never receives it and
    never talks to Storage directly for managed datasets.
    """

    def __init__(self, client=None, bucket: str | None = None):
        self._client = client
        self._bucket_name = bucket or os.getenv(
            "INSIGHTFLOW_DATASET_STORAGE_BUCKET", "managed-datasets"
        )

    @staticmethod
    def _component(value: str, field: str) -> str:
        import re
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}", value):
            raise ValueError(f"Invalid {field}.")
        return value

    def _client_for_use(self):
        if self._client is not None:
            return self._client
        url = os.getenv("SUPABASE_URL", "").strip()
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
        if not url:
            ref = os.getenv("SUPABASE_PROJECT_REF", "").strip()
            if ref:
                url = f"https://{ref}.supabase.co"
        if not url or not key:
            raise RuntimeError(
                "Supabase Storage archive is enabled but SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY are not configured."
            )
        try:
            from supabase import create_client
        except ImportError as exc:
            raise RuntimeError("Supabase Storage archive requires the Python 'supabase' package.") from exc
        self._client = create_client(url, key)
        return self._client

    def object_path(self, *, organization_id: str, dataset_id: str, version_id: str) -> str:
        return (
            f"organizations/{self._component(organization_id, 'organization ID')}/"
            f"datasets/{self._component(dataset_id, 'dataset ID')}/"
            f"versions/{self._component(version_id, 'version ID')}/original.csv"
        )

    def upload_stream(
        self, *, organization_id: str, dataset_id: str, version_id: str,
        stream: BinaryIO, original_filename: str, content_type: str | None,
    ) -> StoredDatasetObject:
        # supabase-py currently accepts a file-like body; the FastAPI upload is
        # already spooled/streamed and is not copied into a second full bytes object.
        data = stream
        path = self.object_path(
            organization_id=organization_id, dataset_id=dataset_id, version_id=version_id
        )
        client = self._client_for_use()
        client.storage.from_(self._bucket_name).upload(
            file=data,
            path=path,
            file_options={"content-type": content_type or "text/csv", "upsert": "false"},
        )
        stream.seek(0)
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        stream.seek(0)
        return StoredDatasetObject(path, size, content_type or "text/csv", digest.hexdigest())

    def download(self, *, organization_id: str, dataset_id: str, version_id: str) -> bytes:
        path = self.object_path(
            organization_id=organization_id, dataset_id=dataset_id, version_id=version_id
        )
        return self._client_for_use().storage.from_(self._bucket_name).download(path)

    def delete(self, *, organization_id: str, dataset_id: str, version_id: str) -> None:
        path = self.object_path(
            organization_id=organization_id, dataset_id=dataset_id, version_id=version_id
        )
        self._client_for_use().storage.from_(self._bucket_name).remove([path])

    def exists(self, *, organization_id: str, dataset_id: str, version_id: str) -> bool:
        path = self.object_path(
            organization_id=organization_id, dataset_id=dataset_id, version_id=version_id
        )
        prefix = "/".join(path.split("/")[:-1])
        name = path.rsplit("/", 1)[-1]
        try:
            items = self._client_for_use().storage.from_(self._bucket_name).list(prefix)
            return any(item.get("name") == name for item in (items or []))
        except Exception:
            return False


def archive_original_enabled() -> bool:
    return os.getenv("INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL", "false").strip().lower() in {
        "1", "true", "yes", "on"
    }
