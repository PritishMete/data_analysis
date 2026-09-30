from __future__ import annotations

import csv
import io
import os
import re
import uuid
from typing import Any, BinaryIO, Iterator

from sqlalchemy import select

from firebase_authz.service import AuthenticationRequired, AuthzError, PermissionDenied, require_email_verified, verify_id_token
from firebase_authz.supabase_provider import (
    audit_dataset_event,
    authorization_context,
    authorize,
    authorize_dataset,
    create_working_copy,
    delete_dataset_authorization,
    register_dataset,
)
from datasets.models import DatasetRow
from datasets.repository import DatasetRepository
from datasets.service import DatasetRegistryService
from schema_intelligence.repository import RelationshipRepository
from schema_intelligence.service import SchemaIntelligenceService

from .provider import SupabaseDatasetStorageProvider, archive_original_enabled

MAX_DATASET_BYTES = int(
    os.getenv("INSIGHTFLOW_DATASET_MAX_BYTES", str(100 * 1024 * 1024))
)
BLOCKED_EXTENSIONS = {".exe", ".dll", ".bat", ".cmd", ".com", ".msi", ".scr", ".ps1", ".sh"}


def _safe_filename(filename: str) -> str:
    name = os.path.basename(str(filename or "").replace("\\", "/")).strip()
    if (
        not name
        or name in {".", ".."}
        or len(name) > 255
        or "/" in name
        or "\\" in name
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
    ):
        raise ValueError("Unsafe dataset filename.")
    extension = os.path.splitext(name)[1].lower()
    if extension in BLOCKED_EXTENSIONS:
        raise ValueError("This file type is not accepted as a managed dataset.")
    if extension != ".csv":
        raise ValueError("Only safe CSV files are accepted as managed datasets.")
    return name


def _claims(token: str) -> dict[str, Any]:
    return require_email_verified(verify_id_token(token))


def _authorization_context(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise PermissionDenied("User is not an active member of this workspace.")
    return context


def _authorize_upload(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    return authorize(claims, workspace_id, "dataset.upload")


def _authorize_delete(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    return authorize(claims, workspace_id, "dataset.delete")


def _authorize_dataset(
    claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str
):
    context = _authorization_context(claims, workspace_id)
    if (
        action in {"dataset.view_original", "dataset.create_working_copy"}
        and "dataset.manage_acl" in context.get("permissions", [])
    ):
        return authorize(claims, workspace_id, action)
    return authorize_dataset(claims, workspace_id, dataset_id, action)


def _audit_safely(
    workspace_id: str,
    actor_uid: str,
    action: str,
    outcome: str,
    *,
    resource_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    try:
        payload = dict(metadata or {})
        if resource_id:
            payload["resource_id"] = resource_id
        audit_dataset_event(
            workspace_id, actor_uid, action, outcome, metadata=payload
        )
    except Exception:
        pass


def _structured_summary(dataset, version_count: int) -> dict[str, Any]:
    current = next(
        (
            version
            for version in getattr(dataset, "versions", [])
            if version.version_id == dataset.current_version_id
        ),
        None,
    )
    return {
        "dataset_id": dataset.dataset_id,
        "organization_id": dataset.organization_id,
        "display_name": dataset.dataset_name,
        "dataset_name": dataset.dataset_name,
        "original_filename": current.original_filename if current else dataset.original_filename,
        "content_type": (current.content_type if current else None) or dataset.content_type or "text/csv",
        "file_size": current.file_size if current else dataset.file_size,
        "current_version": dataset.current_version_id,
        "version": dataset.version_number,
        "version_count": version_count,
        "row_count": current.row_count if current else dataset.row_count,
        "column_count": current.column_count if current else dataset.column_count,
        "uploaded_by_uid": (current.created_by if current else None) or dataset.uploaded_by,
        "uploaded_at": (
            current.created_at.isoformat()
            if current and current.created_at
            else dataset.created_at.isoformat()
            if dataset.created_at
            else None
        ),
        "created_at": dataset.created_at.isoformat() if dataset.created_at else None,
        "status": dataset.status,
        "protected_original": True,
        "storage_provider": current.storage_provider if current else dataset.storage_provider,
        "storage_mode": "sql_structured",
        "archive_original": bool(
            current and current.storage_provider == "supabase_storage"
        ),
    }


def list_authorized_datasets(
    *, workspace_id: str, token: str
) -> list[dict[str, Any]]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        result = []
        for dataset in repo.list_by_organization(organization_id, limit=100):
            if dataset.status == "deleted":
                continue
            try:
                _authorize_dataset(
                    claims, workspace_id, dataset.dataset_id, "dataset.view_original"
                )
            except AuthzError:
                continue
            result.append(
                _structured_summary(
                    dataset, len(repo.list_versions(dataset.dataset_id))
                )
            )
        return result
    finally:
        repo.db.close()


def get_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != workspace_id:
            raise FileNotFoundError("Dataset not found.")
        return _structured_summary(dataset, len(repo.list_versions(dataset_id)))
    finally:
        repo.db.close()


def get_managed_dataset_rows(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str,
    version_id: str | None,
    limit: int,
    offset: int,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != workspace_id:
            raise FileNotFoundError("Dataset not found.")
        version = repo.get_version(dataset_id, version_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("Dataset version not found.")
        rows = repo.get_rows(version.version_pk, limit=limit, offset=offset)
        return {
            "dataset_id": dataset_id,
            "version_id": version.version_id,
            "row_count": version.row_count,
            "column_count": version.column_count,
            "offset": max(0, offset),
            "limit": min(max(1, limit), 10000),
            "rows": [
                {"row_number": row.row_number, "row_data": row.row_data}
                for row in rows
            ],
        }
    finally:
        repo.db.close()


def stream_managed_dataset_csv(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str,
    version_id: str | None = None,
) -> tuple[Iterator[bytes], dict[str, Any]]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    dataset = repo.get_by_id(dataset_id)
    if dataset is None or dataset.organization_id != workspace_id:
        repo.db.close()
        raise FileNotFoundError("Dataset not found.")
    version = repo.get_version(dataset_id, version_id)
    if version is None or version.status != "ready":
        repo.db.close()
        raise FileNotFoundError("Dataset version not found.")

    columns = repo.get_columns_for_version(version.version_pk)
    if not columns:
        columns = repo.get_columns(dataset_id)

    def generate() -> Iterator[bytes]:
        try:
            header = io.StringIO()
            csv.writer(header, lineterminator="\r\n").writerow(
                [column.column_name for column in columns]
            )
            yield header.getvalue().encode("utf-8")

            stmt = (
                select(DatasetRow.row_data)
                .where(DatasetRow.version_pk == version.version_pk)
                .order_by(DatasetRow.row_number.asc())
                .execution_options(yield_per=1000)
            )
            result = repo.db.execute(stmt)
            for (row_data,) in result:
                line = io.StringIO()
                writer = csv.writer(line, lineterminator="\r\n")
                writer.writerow([
                    "" if row_data.get(column.column_name) is None
                    else row_data.get(column.column_name)
                    for column in columns
                ])
                yield line.getvalue().encode("utf-8")
            _audit_safely(
                workspace_id,
                str(claims["uid"]),
                "dataset.download",
                "succeeded",
                resource_id=dataset_id,
                metadata={"version_id": version.version_id, "mode": "structured_csv_export"},
            )
        finally:
            repo.db.close()

    return generate(), {
        "version_id": version.version_id,
        "original_filename": version.original_filename,
        "dataset_id": dataset_id,
    }


def _register_authorization(claims: dict[str, Any], workspace_id: str, dataset_id: str) -> None:
    register_dataset(
        claims,
        workspace_id,
        dataset_id,
        str(claims["uid"]),
        True,
    )


def _unregister_authorization(workspace_id: str, dataset_id: str) -> None:
    try:
        delete_dataset_authorization(workspace_id, dataset_id)
    except Exception:
        pass


def _cleanup_sql_version(
    repo: DatasetRepository,
    dataset_id: str,
    version_id: str,
    was_new_dataset: bool,
) -> None:
    with repo.db.begin():
        dataset = repo.get_by_id(dataset_id)
        version = repo.get_version(dataset_id, version_id)
        if version is not None:
            repo.db.delete(version)
        if dataset is not None and was_new_dataset:
            repo.db.delete(dataset)
        repo.db.flush()


def upload_managed_dataset_stream(
    *,
    workspace_id: str,
    token: str,
    filename: str,
    stream: BinaryIO,
    content_type: str | None,
    provider: SupabaseDatasetStorageProvider | None = None,
    dataset_id: str | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_upload(claims, workspace_id)
    safe_name = _safe_filename(filename)
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])

    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    registry = DatasetRegistryService(repo)
    registration = None
    stored = None
    new_dataset = dataset_id is None
    provider = provider or SupabaseDatasetStorageProvider()
    try:
        registration = registry.register_csv_stream(
            file_obj=stream,
            filename=safe_name,
            organization_id=organization_id,
            dataset_name=safe_name,
            uploaded_by=str(context.get("principal_id") or claims["uid"]),
            existing_dataset_id=dataset_id,
            content_type=content_type or "text/csv",
            max_bytes=MAX_DATASET_BYTES,
        )
        if registration.registration.was_duplicate:
            _audit_safely(
                workspace_id,
                str(claims["uid"]),
                "dataset.upload",
                "duplicate",
                resource_id=registration.registration.dataset.dataset_id,
                metadata={"version_id": registration.version.version_id},
            )
            return _structured_summary(
                registration.registration.dataset,
                len(repo.list_versions(registration.registration.dataset.dataset_id)),
            )

        if new_dataset:
            _register_authorization(
                claims, workspace_id, registration.registration.dataset.dataset_id
            )

        if not registration.sample.empty:
            intelligence = SchemaIntelligenceService(
                repo, RelationshipRepository(repo.db)
            )
            intelligence.analyze_dataset(
                registration.registration.dataset.dataset_id,
                registration.sample,
                version_pk=registration.version.version_pk,
            )

        if archive_original_enabled():
            stream.seek(0)
            stored = provider.upload_stream(
                organization_id=organization_id,
                dataset_id=registration.registration.dataset.dataset_id,
                version_id=registration.version.version_id,
                stream=stream,
                original_filename=safe_name,
                content_type=content_type or "text/csv",
            )

        dataset = registry.finalize_version(
            registration.registration.dataset.dataset_id,
            registration.version.version_id,
            storage_provider="supabase_storage" if stored else None,
            storage_object_id=stored.storage_object_id if stored else None,
        )
        _audit_safely(
            workspace_id,
            str(claims["uid"]),
            "dataset.upload" if new_dataset else "dataset.version_upload",
            "succeeded",
            resource_id=dataset.dataset_id,
            metadata={
                "version_id": registration.version.version_id,
                "row_count": dataset.row_count,
                "column_count": dataset.column_count,
                "storage_mode": "sql_structured",
            },
        )
        return _structured_summary(dataset, len(repo.list_versions(dataset.dataset_id)))
    except Exception:
        if stored is not None:
            try:
                provider.delete(
                    organization_id=organization_id,
                    dataset_id=registration.registration.dataset.dataset_id if registration else (dataset_id or ""),
                    version_id=registration.version.version_id if registration else "v1",
                )
            except Exception:
                pass
        if registration is not None:
            try:
                _cleanup_sql_version(
                    repo,
                    registration.registration.dataset.dataset_id,
                    registration.version.version_id,
                    new_dataset,
                )
            except Exception:
                pass
            if new_dataset:
                _unregister_authorization(
                    workspace_id, registration.registration.dataset.dataset_id
                )
        _audit_safely(
            workspace_id,
            str(claims["uid"]),
            "dataset.upload" if new_dataset else "dataset.version_upload",
            "failed",
            resource_id=dataset_id,
        )
        raise
    finally:
        repo.db.close()


def upload_managed_dataset(
    *,
    workspace_id: str,
    token: str,
    filename: str,
    data: bytes,
    content_type: str | None,
    provider: SupabaseDatasetStorageProvider | None = None,
    dataset_id: str | None = None,
) -> dict[str, Any]:
    return upload_managed_dataset_stream(
        workspace_id=workspace_id,
        token=token,
        filename=filename,
        stream=io.BytesIO(data),
        content_type=content_type,
        provider=provider,
        dataset_id=dataset_id,
    )


def delete_managed_dataset(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str,
    provider: SupabaseDatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_delete(claims, workspace_id)
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    provider = provider or SupabaseDatasetStorageProvider()
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("Dataset not found.")
        versions = repo.list_versions(dataset_id)
        for version in versions:
            if version.storage_provider == "supabase_storage":
                provider.delete(
                    organization_id=organization_id,
                    dataset_id=dataset_id,
                    version_id=version.version_id,
                )
        repo.delete_dataset(dataset_id)
        _unregister_authorization(organization_id, dataset_id)
        _audit_safely(
            workspace_id,
            str(claims["uid"]),
            "dataset.delete",
            "succeeded",
            resource_id=dataset_id,
        )
        return {"dataset_id": dataset_id, "status": "deleted"}
    finally:
        repo.db.close()


def create_managed_working_copy(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str,
    provider: SupabaseDatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.create_working_copy")
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("Dataset not found.")
        version = repo.get_version(dataset_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("Current dataset version is not READY.")
        working_copy_id = f"wc_{uuid.uuid4().hex}"
        metadata = create_working_copy(
            claims,
            workspace_id,
            dataset_id,
            working_copy_id,
            version.version_id,
        )
        _audit_safely(
            workspace_id,
            str(claims["uid"]),
            "working_copy.create",
            "succeeded",
            resource_id=working_copy_id,
            metadata={
                "source_dataset_id": dataset_id,
                "source_version": version.version_id,
            },
        )
        return {
            **metadata,
            "structured_dataset_id": dataset_id,
            "structured_version_id": version.version_id,
        }
    finally:
        repo.db.close()
