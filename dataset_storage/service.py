from __future__ import annotations

import io
import os
import re
import uuid
from datetime import datetime, timezone
from typing import Any, BinaryIO

from firebase_authz.service import (
    AuthzError,
    AuthenticationRequired,
    PermissionDenied,
    _dataset,
    _effective_role_level,
    _workspace,
    audit_event,
    authorization,
    authorize_dataset,
    create_working_copy,
    initialize_firebase,
    require_email_verified,
    verify_id_token,
)
from firebase_authz.schema import ROLE_LEVELS
from datasets.repository import DatasetRepository
from datasets.service import DatasetRegistryService
from schema_intelligence.repository import RelationshipRepository
from schema_intelligence.service import SchemaIntelligenceService

from .provider import DatasetStorageProvider, FirebaseDatasetStorageProvider

MAX_DATASET_BYTES = int(os.getenv("INSIGHTFLOW_DATASET_MAX_BYTES", str(100 * 1024 * 1024)))
BLOCKED_EXTENSIONS = {".exe", ".dll", ".bat", ".cmd", ".com", ".msi", ".scr", ".ps1", ".sh"}


def _now_ms() -> int:
    return int(datetime.now(timezone.utc).timestamp() * 1000)


def _safe_filename(filename: str) -> str:
    name = os.path.basename(str(filename or "").replace("\\", "/")).strip()
    if not name or name in {".", ".."} or len(name) > 255 or "/" in name or "\\" in name:
        raise ValueError("Unsafe dataset filename.")
    if os.path.splitext(name)[1].lower() in BLOCKED_EXTENSIONS:
        raise ValueError("This file type is not accepted as a managed dataset.")
    if not name.lower().endswith(".csv"):
        raise ValueError("Managed datasets currently accept CSV files only.")
    if any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise ValueError("Unsafe dataset filename.")
    return name


def _provider(provider: DatasetStorageProvider | None) -> DatasetStorageProvider:
    return provider or FirebaseDatasetStorageProvider()


def _claims(token: str) -> dict[str, Any]:
    return require_email_verified(verify_id_token(token))


def _provider_mode() -> str:
    return os.getenv("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower()


def _authorization_context(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    if _provider_mode() == "supabase":
        from firebase_authz.supabase_provider import authorization_context
        context = authorization_context(claims, workspace_id)
        if not context.get("workspace_authorized"):
            raise PermissionDenied("User is not an active member of this workspace.")
        return context
    from firebase_authz.service import authentication_context
    context = authentication_context(
        str(claims["uid"]), workspace_id, True,
        email=str(claims.get("email") or ""),
    )
    if not context.get("workspace_authorized"):
        raise PermissionDenied("User is not an active member of this workspace.")
    return context


def _authorize_upload(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    if _provider_mode() == "supabase":
        from firebase_authz.supabase_provider import authorize
        return authorize(claims, workspace_id, "dataset.upload")
    return authorization(str(claims["uid"]), workspace_id, "dataset.upload")


def _authorize_delete(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    if _provider_mode() == "supabase":
        from firebase_authz.supabase_provider import authorize
        return authorize(claims, workspace_id, "dataset.delete")
    return authorization(str(claims["uid"]), workspace_id, "dataset.delete")


def _authorize_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str):
    if _provider_mode() == "supabase":
        from firebase_authz.supabase_provider import authorize_dataset as provider_authorize_dataset
        return provider_authorize_dataset(claims, workspace_id, dataset_id, action)
    return authorize_dataset(str(claims["uid"]), workspace_id, dataset_id, action)


def _audit_safely(workspace_id: str, actor_uid: str, action: str, outcome: str, **kwargs) -> None:
    try:
        if _provider_mode() == "supabase":
            from firebase_authz.supabase_provider import audit_dataset_event
            metadata = dict(kwargs.get("metadata") or {})
            if kwargs.get("resource_id"):
                metadata["resource_id"] = kwargs["resource_id"]
            audit_dataset_event(workspace_id, actor_uid, action, outcome, metadata=metadata)
        else:
            audit_event(workspace_id, actor_uid, action, outcome, **kwargs)
    except Exception:
        pass


def _next_version(dataset: dict[str, Any]) -> str:
    versions = dataset.get("versions") or {}
    highest = 0
    for version_id in versions:
        match = re.fullmatch(r"v(\d+)", str(version_id))
        if match:
            highest = max(highest, int(match.group(1)))
    return f"v{highest + 1}"


def _role_can_manage_all_datasets(workspace: dict[str, Any], uid: str) -> bool:
    member = (workspace.get("members") or {}).get(uid)
    if not isinstance(member, dict):
        return False
    return _effective_role_level(member) >= ROLE_LEVELS["manager"]


def _structured_summary(dataset, version_count: int) -> dict[str, Any]:
    current = next(
        (version for version in getattr(dataset, "versions", [])
         if version.version_id == dataset.current_version_id),
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
            current.created_at.isoformat() if current and current.created_at
            else dataset.created_at.isoformat() if dataset.created_at else None
        ),
        "created_at": dataset.created_at.isoformat() if dataset.created_at else None,
        "status": dataset.status,
        "protected_original": True,
        "storage_provider": current.storage_provider if current else dataset.storage_provider,
        "storage_mode": "sql_structured",
    }


def _legacy_summaries(workspace_id: str, actor: str) -> list[dict[str, Any]]:
    if _provider_mode() == "supabase":
        return []
    workspace = _workspace(workspace_id)
    manager = _role_can_manage_all_datasets(workspace, actor)
    result = []
    for dataset_id, dataset in (workspace.get("datasets") or {}).items():
        if not isinstance(dataset, dict) or dataset.get("status") == "deleted":
            continue
        allowed = manager or actor == dataset.get("owner_uid")
        if not allowed:
            grant = (dataset.get("grants") or {}).get(actor) or {}
            allowed = "dataset.view_original" in set(grant.get("permissions") or [])
        if not allowed:
            continue
        result.append({
            "dataset_id": dataset_id,
            "organization_id": workspace_id,
            "display_name": dataset.get("display_name") or dataset.get("original_filename") or dataset_id,
            "original_filename": dataset.get("original_filename"),
            "content_type": dataset.get("content_type"),
            "file_size": dataset.get("file_size"),
            "current_version": dataset.get("current_version"),
            "version": dataset.get("version", 1),
            "version_count": len(dataset.get("versions") or {}),
            "row_count": None,
            "column_count": None,
            "uploaded_by_uid": dataset.get("uploaded_by_uid") or dataset.get("owner_uid"),
            "created_at": dataset.get("created_at"),
            "status": "legacy_binary",
            "protected_original": dataset.get("protected_original") is True,
            "storage_mode": "legacy_binary",
        })
    return result


def list_authorized_datasets(*, workspace_id: str, token: str) -> list[dict[str, Any]]:
    claims = _claims(token)
    actor = str(claims["uid"])
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])
    repo = DatasetRepository(__import__("core.db", fromlist=["SessionLocal"]).SessionLocal())
    try:
        datasets = repo.list_by_organization(organization_id, limit=100)
        result = []
        for dataset in datasets:
            if dataset.status != "ready":
                continue
            try:
                _authorize_dataset(claims, workspace_id, dataset.dataset_id, "dataset.view_original")
            except AuthzError:
                continue
            result.append(_structured_summary(dataset, len(repo.list_versions(dataset.dataset_id))))
        if _provider_mode() != "supabase":
            existing_ids = {item["dataset_id"] for item in result}
            result.extend(item for item in _legacy_summaries(workspace_id, actor) if item["dataset_id"] not in existing_ids)
        return result
    finally:
        repo.db.close()


def _register_authorization(claims: dict[str, Any], workspace_id: str, dataset_id: str, token: str) -> None:
    actor = str(claims["uid"])
    if _provider_mode() == "supabase":
        from firebase_authz.supabase_provider import register_dataset
        register_dataset(claims, workspace_id, dataset_id, actor, True)
        return
    from firebase_admin import db
    initialize_firebase()
    register_dataset(workspace_id, dataset_id, actor, token, True)
    db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}").update({
        "display_name": dataset_id,
        "organization_id": workspace_id,
        "status": "active",
        "protected_original": True,
    })


def _unregister_authorization(workspace_id: str, dataset_id: str) -> None:
    try:
        if _provider_mode() == "supabase":
            from firebase_authz.supabase_provider import delete_dataset_authorization
            delete_dataset_authorization(workspace_id, dataset_id)
        else:
            initialize_firebase()
            from firebase_admin import db
            db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}").delete()
    except Exception:
        pass


def _storage_stream(provider: DatasetStorageProvider, stream: BinaryIO, **kwargs):
    method = getattr(provider, "upload_stream", None)
    if method is not None:
        return method(stream=stream, **kwargs)
    return provider.upload(data=stream.read(), **kwargs)


def _cleanup_sql_version(repo: DatasetRepository, dataset_id: str, version_id: str, was_new_dataset: bool) -> None:
    with repo.db.begin():
        dataset = repo.get_by_id(dataset_id)
        version = repo.get_version(dataset_id, version_id)
        if version is not None:
            repo.db.delete(version)
        if dataset is not None:
            if was_new_dataset:
                repo.db.delete(dataset)
            else:
                dataset.status = "ready"
        repo.db.flush()


def upload_managed_dataset_stream(
    *, workspace_id: str, token: str, filename: str, stream: BinaryIO,
    content_type: str | None, provider: DatasetStorageProvider | None = None,
    dataset_id: str | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_upload(claims, workspace_id)
    safe_name = _safe_filename(filename)
    context = _authorization_context(claims, workspace_id)
    organization_id = str(context["organization_id"])
    provider = _provider(provider)
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    registry = DatasetRegistryService(repo)
    registration = None
    stored = None
    new_dataset = dataset_id is None
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
            _audit_safely(workspace_id, str(claims["uid"]), "dataset.upload", "duplicate",
                          resource_id=registration.registration.dataset.dataset_id,
                          metadata={"version_id": registration.version.version_id})
            return _structured_summary(
                registration.registration.dataset,
                len(repo.list_versions(registration.registration.dataset.dataset_id)),
            )

        stream.seek(0)
        stored = _storage_stream(
            provider, stream, workspace_id=workspace_id,
            dataset_id=registration.registration.dataset.dataset_id,
            version_id=registration.version.version_id,
            original_filename=safe_name,
            content_type=content_type or "text/csv",
        )

        if new_dataset:
            _register_authorization(claims, workspace_id, registration.registration.dataset.dataset_id, token)

        if not registration.sample.empty:
            intelligence = SchemaIntelligenceService(
                repo,
                RelationshipRepository(repo.db),
            )
            intelligence.analyze_dataset(
                registration.registration.dataset.dataset_id,
                registration.sample,
            )

        dataset = registry.finalize_version(
            registration.registration.dataset.dataset_id,
            registration.version.version_id,
            storage_provider="firebase_storage",
            storage_object_id=stored.storage_object_id,
        )
        _audit_safely(
            workspace_id, str(claims["uid"]), "dataset.upload" if new_dataset else "dataset.version_upload",
            "succeeded", resource_id=dataset.dataset_id,
            metadata={"version_id": registration.version.version_id, "row_count": dataset.row_count,
                      "column_count": dataset.column_count},
        )
        return _structured_summary(dataset, len(repo.list_versions(dataset.dataset_id)))
    except Exception as exc:
        if stored is not None:
            try:
                provider.delete(
                    workspace_id=workspace_id,
                    dataset_id=registration.registration.dataset.dataset_id if registration else (dataset_id or ""),
                    version_id=registration.version.version_id if registration else "v1",
                )
            except Exception:
                pass
        if registration is not None:
            _cleanup_sql_version(
                repo, registration.registration.dataset.dataset_id,
                registration.version.version_id, new_dataset,
            )
            if new_dataset:
                _unregister_authorization(workspace_id, registration.registration.dataset.dataset_id)
        _audit_safely(
            workspace_id, str(claims["uid"]), "dataset.upload" if new_dataset else "dataset.version_upload",
            "failed", resource_id=dataset_id,
        )
        raise
    finally:
        repo.db.close()


def upload_managed_dataset(
    *, workspace_id: str, token: str, filename: str, data: bytes,
    content_type: str | None, provider: DatasetStorageProvider | None = None,
    dataset_id: str | None = None,
) -> dict[str, Any]:
    return upload_managed_dataset_stream(
        workspace_id=workspace_id, token=token, filename=filename,
        stream=io.BytesIO(data), content_type=content_type,
        provider=provider, dataset_id=dataset_id,
    )


def download_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str, version_id: str | None = None,
    provider: DatasetStorageProvider | None = None,
):
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    provider = _provider(provider)
    workspace = _workspace(workspace_id) if _provider_mode() != "supabase" else None
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is not None and dataset.organization_id:
            version = repo.get_version(dataset_id, version_id)
            if version is None:
                raise FileNotFoundError("Dataset version not found.")
            data = provider.download(workspace_id=workspace_id, dataset_id=dataset_id, version_id=version.version_id)
            _audit_safely(workspace_id, str(claims["uid"]), "dataset.download", "succeeded",
                          resource_id=dataset_id, metadata={"version_id": version.version_id})
            return data, {
                "version_id": version.version_id, "original_filename": version.original_filename,
                "content_type": version.content_type or "text/csv",
                "dataset_id": dataset_id, "protected_original": True,
            }
    finally:
        repo.db.close()
    if workspace is None:
        raise FileNotFoundError("Dataset not found.")
    dataset = _dataset(workspace, dataset_id)
    version_id = version_id or str(dataset.get("current_version") or "v1")
    version = (dataset.get("versions") or {}).get(version_id)
    if not isinstance(version, dict):
        raise FileNotFoundError("Dataset version not found.")
    data = provider.download(workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id)
    return data, {**version, "dataset_id": dataset_id, "protected_original": True}


def get_managed_dataset(*, workspace_id: str, token: str, dataset_id: str) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None:
            raise FileNotFoundError("Dataset not found.")
        return _structured_summary(dataset, len(repo.list_versions(dataset_id)))
    finally:
        repo.db.close()


def get_managed_dataset_rows(
    *, workspace_id: str, token: str, dataset_id: str, version_id: str | None,
    limit: int, offset: int,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        version = repo.get_version(dataset_id, version_id)
        if dataset is None or version is None or version.status != "ready":
            raise FileNotFoundError("Dataset version not found.")
        rows = repo.get_rows(version.version_pk, limit=limit, offset=offset)
        return {
            "dataset_id": dataset_id, "version_id": version.version_id,
            "row_count": version.row_count, "column_count": version.column_count,
            "offset": max(0, offset), "limit": min(max(1, limit), 10000),
            "rows": [{"row_number": row.row_number, "row_data": row.row_data} for row in rows],
        }
    finally:
        repo.db.close()


def delete_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str,
    provider: DatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_delete(claims, workspace_id)
    context = _authorization_context(claims, workspace_id)
    provider = _provider(provider)
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is not None:
            if dataset.organization_id != str(context["organization_id"]):
                raise PermissionDenied("Dataset is not accessible in this organization.")
            versions = repo.list_versions(dataset_id)
            for version in versions:
                try:
                    provider.delete(workspace_id=workspace_id, dataset_id=dataset_id, version_id=version.version_id)
                except Exception:
                    pass
            repo.delete_dataset(dataset_id)
            _unregister_authorization(workspace_id, dataset_id)
            _audit_safely(workspace_id, str(claims["uid"]), "dataset.delete", "succeeded", resource_id=dataset_id)
            return {"dataset_id": dataset_id, "status": "deleted"}
    finally:
        repo.db.close()
    # Legacy binary-only compatibility path.
    authorization(str(claims["uid"]), workspace_id, "dataset.delete")
    workspace = _workspace(workspace_id)
    dataset = _dataset(workspace, dataset_id)
    if dataset.get("protected_original") is not True:
        raise PermissionDenied("Only protected managed originals are deletable here.")
    initialize_firebase()
    from firebase_admin import db
    ref = db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}")
    ref.update({"status": "deleting", "updated_at": _now_ms()})
    for version_id in (dataset.get("versions") or {}):
        provider.delete(workspace_id=workspace_id, dataset_id=dataset_id, version_id=str(version_id))
    ref.update({"status": "deleted", "updated_at": _now_ms(), "grants": {}})
    _audit_safely(workspace_id, str(claims["uid"]), "dataset.delete", "succeeded", resource_id=dataset_id)
    return {"dataset_id": dataset_id, "status": "deleted"}


def create_managed_working_copy(
    *, workspace_id: str, token: str, dataset_id: str,
    provider: DatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.create_working_copy")
    provider = _provider(provider)
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is not None:
            version_id = dataset.current_version_id or "v1"
            if repo.get_version(dataset_id, version_id) is None:
                raise FileNotFoundError("Current dataset version is not available.")
            working_copy_id = f"wc_{uuid.uuid4().hex}"
            stored = provider.create_working_copy_object(
                workspace_id=workspace_id, dataset_id=dataset_id,
                version_id=version_id, working_copy_id=working_copy_id,
            )
            if _provider_mode() == "supabase":
                from firebase_authz.supabase_provider import create_working_copy as provider_create_working_copy
                metadata = provider_create_working_copy(claims, workspace_id, dataset_id, working_copy_id, version_id)
            else:
                metadata = create_working_copy(workspace_id, dataset_id, token, working_copy_id, version_id)
                initialize_firebase()
                from firebase_admin import db
                db.reference(f"workspaces/{workspace_id}/working_copies/{working_copy_id}").update({
                    "storage_object_id": stored.storage_object_id,
                    "storage_provider": "firebase_storage",
                    "structured_dataset_id": dataset_id,
                    "structured_version_id": version_id,
                })
            _audit_safely(workspace_id, str(claims["uid"]), "working_copy.create", "succeeded",
                          resource_id=working_copy_id,
                          metadata={"source_dataset_id": dataset_id, "source_version": version_id})
            return {
                **metadata, "storage_object_id": stored.storage_object_id,
                "structured_dataset_id": dataset_id, "structured_version_id": version_id,
            }
    finally:
        repo.db.close()
    # Legacy binary-only path.
    workspace = _workspace(workspace_id)
    version_id = str(_dataset(workspace, dataset_id).get("current_version") or "v1")
    working_copy_id = f"wc_{uuid.uuid4().hex}"
    stored = provider.create_working_copy_object(
        workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id,
        working_copy_id=working_copy_id,
    )
    metadata = create_working_copy(workspace_id, dataset_id, token, working_copy_id, version_id)
    return {**metadata, "storage_object_id": stored.storage_object_id}
