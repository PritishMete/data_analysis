from __future__ import annotations

import os
import re
import uuid
from datetime import datetime, timezone
from typing import Any

from firebase_authz.service import (
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
    return name


def _provider(provider: DatasetStorageProvider | None) -> DatasetStorageProvider:
    return provider or FirebaseDatasetStorageProvider()


def _claims(token: str) -> dict[str, Any]:
    return require_email_verified(verify_id_token(token))


def _authorize_dataset(claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str):
    if os.getenv("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
        from firebase_authz.supabase_provider import authorize_dataset as provider_authorize_dataset
        return provider_authorize_dataset(claims, workspace_id, dataset_id, action)
    return authorize_dataset(str(claims["uid"]), workspace_id, dataset_id, action)


def _audit_safely(workspace_id: str, actor_uid: str, action: str, outcome: str, **kwargs) -> None:
    try:
        audit_event(workspace_id, actor_uid, action, outcome, **kwargs)
    except Exception:
        # Authorization/storage failure must never become a second user-visible failure.
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


def list_authorized_datasets(*, workspace_id: str, token: str) -> list[dict[str, Any]]:
    claims = _claims(token)
    actor = str(claims["uid"])
    workspace = _workspace(workspace_id)
    member = (workspace.get("members") or {}).get(actor)
    if not isinstance(member, dict) or str(member.get("status") or "active") != "active":
        raise PermissionDenied("User membership is not active.")

    result: list[dict[str, Any]] = []
    manager = _role_can_manage_all_datasets(workspace, actor)
    for dataset_id, dataset in (workspace.get("datasets") or {}).items():
        if not isinstance(dataset, dict) or dataset.get("status") == "deleted":
            continue
        if manager or actor == dataset.get("owner_uid"):
            allowed = True
        else:
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
            "protected_original": dataset.get("protected_original") is True,
            "status": dataset.get("status", "active"),
            "uploaded_by_uid": dataset.get("uploaded_by_uid") or dataset.get("owner_uid"),
            "created_at": dataset.get("created_at"),
            "updated_at": dataset.get("updated_at"),
        })
    return result


def upload_managed_dataset(
    *,
    workspace_id: str,
    token: str,
    filename: str,
    data: bytes,
    content_type: str | None,
    provider: DatasetStorageProvider | None = None,
    dataset_id: str | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "dataset.upload")
    if not data:
        raise ValueError("Dataset file is empty.")
    if len(data) > MAX_DATASET_BYTES:
        raise ValueError(f"Dataset exceeds the configured {MAX_DATASET_BYTES} byte limit.")

    safe_name = _safe_filename(filename)
    provider = _provider(provider)
    workspace = _workspace(workspace_id)
    existing = None

    if dataset_id is not None:
        dataset_id = str(dataset_id)
        existing = _dataset(workspace, dataset_id)
        if existing.get("status") == "deleted":
            raise PermissionDenied("Deleted datasets cannot receive new versions.")
        version_id = _next_version(existing)
    else:
        dataset_id = f"ds_{uuid.uuid4().hex}"
        version_id = "v1"

    stored = provider.upload(
        workspace_id=workspace_id,
        dataset_id=dataset_id,
        version_id=version_id,
        data=data,
        original_filename=safe_name,
        content_type=content_type,
    )
    now = _now_ms()
    version_metadata = {
        "version_id": version_id,
        "dataset_id": dataset_id,
        "created_by_uid": actor,
        "created_at": now,
        "storage_provider": "firebase_test",
        "storage_object_id": stored.storage_object_id,
        "content_type": content_type or "application/octet-stream",
        "original_filename": safe_name,
        "file_size": stored.size,
        "checksum": stored.checksum,
    }

    initialize_firebase()
    from firebase_admin import db

    ref = db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}")
    if existing is None:
        metadata = {
            "dataset_id": dataset_id,
            "organization_id": workspace_id,
            "display_name": safe_name,
            "storage_provider": "firebase_test",
            "storage_object_id": stored.storage_object_id,
            "uploaded_by_uid": actor,
            "owner_uid": actor,
            "created_at": now,
            "updated_at": now,
            "content_type": content_type or "application/octet-stream",
            "original_filename": safe_name,
            "file_size": stored.size,
            "version": 1,
            "current_version": version_id,
            "protected_original": True,
            "status": "active",
            "versions": {version_id: version_metadata},
            "grants": {
                actor: {
                    "permissions": [
                        "dataset.view_original",
                        "dataset.create_working_copy",
                        "dataset.manage_acl",
                    ]
                }
            },
        }
        ref.set(metadata)
        _audit_safely(
            workspace_id, actor, "dataset.upload", "succeeded",
            resource_id=dataset_id, metadata={"version_id": version_id, "file_size": stored.size},
        )
        return {k: v for k, v in metadata.items() if k != "grants"}

    # A replacement is always a new physical object/version. Existing ACLs remain intact.
    ref.update({
        "storage_provider": "firebase_test",
        "storage_object_id": stored.storage_object_id,
        "uploaded_by_uid": actor,
        "updated_at": now,
        "content_type": content_type or "application/octet-stream",
        "original_filename": safe_name,
        "file_size": stored.size,
        "version": int(existing.get("version") or 0) + 1,
        "current_version": version_id,
        f"versions/{version_id}": version_metadata,
    })
    _audit_safely(
        workspace_id, actor, "dataset.version_upload", "succeeded",
        resource_id=dataset_id, metadata={"version_id": version_id, "file_size": stored.size},
    )
    return {
        **{k: v for k, v in existing.items() if k != "grants"},
        "storage_provider": "firebase_test",
        "storage_object_id": stored.storage_object_id,
        "uploaded_by_uid": actor,
        "updated_at": now,
        "content_type": content_type or "application/octet-stream",
        "original_filename": safe_name,
        "file_size": stored.size,
        "version": int(existing.get("version") or 0) + 1,
        "current_version": version_id,
    }


def download_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str, version_id: str | None = None,
    provider: DatasetStorageProvider | None = None,
) -> tuple[bytes, dict[str, Any]]:
    claims = _claims(token)
    actor = str(claims["uid"])
    try:
        _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
        workspace = _workspace(workspace_id)
        dataset = _dataset(workspace, dataset_id)
        if dataset.get("status") in {"deleted", "deleting"}:
            raise PermissionDenied("Dataset is not available.")
        version_id = version_id or str(dataset.get("current_version") or "v1")
        version = (dataset.get("versions") or {}).get(version_id)
        if not isinstance(version, dict):
            raise FileNotFoundError("Dataset version not found.")
        data = _provider(provider).download(
            workspace_id=workspace_id, dataset_id=dataset_id, version_id=version_id
        )
    except PermissionDenied:
        _audit_safely(workspace_id, actor, "dataset.download", "denied", resource_id=dataset_id)
        raise
    _audit_safely(
        workspace_id, actor, "dataset.download", "succeeded",
        resource_id=dataset_id, metadata={"version_id": version_id},
    )
    return data, {
        **version,
        "dataset_id": dataset_id,
        "protected_original": dataset.get("protected_original") is True,
    }


def delete_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str,
    provider: DatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    actor = str(claims["uid"])
    authorization(actor, workspace_id, "dataset.delete")
    workspace = _workspace(workspace_id)
    dataset = _dataset(workspace, dataset_id)
    if dataset.get("protected_original") is not True:
        raise PermissionDenied("Only protected managed originals are deletable here.")

    initialize_firebase()
    from firebase_admin import db
    ref = db.reference(f"workspaces/{workspace_id}/datasets/{dataset_id}")
    ref.update({"status": "deleting", "updated_at": _now_ms()})
    try:
        for version_id in (dataset.get("versions") or {}):
            _provider(provider).delete(
                workspace_id=workspace_id, dataset_id=dataset_id, version_id=str(version_id)
            )
    except Exception:
        ref.update({"status": "active", "updated_at": _now_ms()})
        raise
    ref.update({"status": "deleted", "updated_at": _now_ms(), "grants": {}})
    _audit_safely(workspace_id, actor, "dataset.delete", "succeeded", resource_id=dataset_id)
    return {"dataset_id": dataset_id, "status": "deleted"}


def create_managed_working_copy(
    *, workspace_id: str, token: str, dataset_id: str,
    provider: DatasetStorageProvider | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    actor = str(claims["uid"])
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.create_working_copy")
    workspace = _workspace(workspace_id)
    dataset = _dataset(workspace, dataset_id)
    version_id = str(dataset.get("current_version") or "v1")
    working_copy_id = f"wc_{uuid.uuid4().hex}"

    stored = _provider(provider).create_working_copy_object(
        workspace_id=workspace_id,
        dataset_id=dataset_id,
        version_id=version_id,
        working_copy_id=working_copy_id,
    )
    if os.getenv("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
        from firebase_authz.supabase_provider import create_working_copy as provider_create_working_copy
        metadata = provider_create_working_copy(claims, workspace_id, dataset_id, working_copy_id, version_id)
    else:
        metadata = create_working_copy(workspace_id, dataset_id, token, working_copy_id, version_id)
    initialize_firebase()
    from firebase_admin import db
    db.reference(
        f"workspaces/{workspace_id}/working_copies/{working_copy_id}/storage_object_id"
    ).set(stored.storage_object_id)
    db.reference(
        f"workspaces/{workspace_id}/working_copies/{working_copy_id}/storage_provider"
    ).set("firebase_test")
    _audit_safely(
        workspace_id, actor, "working_copy.create", "succeeded",
        resource_id=working_copy_id, metadata={"source_dataset_id": dataset_id, "source_version": version_id},
    )
    return {**metadata, "storage_object_id": stored.storage_object_id}
