from __future__ import annotations

from fastapi import APIRouter, File, Header, HTTPException, UploadFile
from fastapi.responses import Response

from firebase_authz.service import AuthzError, AuthenticationRequired, PermissionDenied

from .service import (
    create_managed_working_copy,
    delete_managed_dataset,
    download_managed_dataset,
    list_authorized_datasets,
    upload_managed_dataset,
)

router = APIRouter(prefix="/v1/managed-datasets", tags=["managed-datasets"])


def _token(value: str | None) -> str:
    if not value or not value.startswith("Bearer "):
        raise HTTPException(401, "Firebase authentication required.")
    return value[7:].strip()


def _workspace(value: str | None) -> str:
    if not value:
        raise HTTPException(403, "Workspace authorization context required.")
    return value.strip()


def _map_error(exc: Exception) -> HTTPException:
    if isinstance(exc, AuthenticationRequired):
        return HTTPException(401, str(exc))
    if isinstance(exc, (PermissionDenied, AuthzError)):
        return HTTPException(403, str(exc))
    if isinstance(exc, FileNotFoundError):
        return HTTPException(404, str(exc))
    if isinstance(exc, ValueError):
        return HTTPException(400, str(exc))
    return HTTPException(500, "Managed dataset operation failed.")


async def _read_limited(file: UploadFile) -> bytes:
    chunks: list[bytes] = []
    total = 0
    from .service import MAX_DATASET_BYTES
    while True:
        chunk = await file.read(min(1024 * 1024, MAX_DATASET_BYTES - total + 1))
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_DATASET_BYTES:
            raise ValueError(f"Dataset exceeds the configured {MAX_DATASET_BYTES} byte limit.")
        chunks.append(chunk)
    return b"".join(chunks)


@router.get("")
def managed_dataset_list(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return {"datasets": list_authorized_datasets(
            workspace_id=_workspace(workspace_id), token=_token(authorization)
        )}
    except Exception as exc:
        raise _map_error(exc)


@router.post("")
async def managed_dataset_upload(
    file: UploadFile = File(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        data = await _read_limited(file)
        result = upload_managed_dataset(
            workspace_id=_workspace(workspace_id),
            token=_token(authorization),
            filename=file.filename or "dataset.bin",
            data=data,
            content_type=file.content_type,
        )
        return {"success": True, "dataset": result}
    except Exception as exc:
        raise _map_error(exc)


@router.post("/{dataset_id}/versions")
async def managed_dataset_version(
    dataset_id: str,
    file: UploadFile = File(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        data = await _read_limited(file)
        result = upload_managed_dataset(
            workspace_id=_workspace(workspace_id),
            token=_token(authorization),
            filename=file.filename or "dataset.bin",
            data=data,
            content_type=file.content_type,
            dataset_id=dataset_id,
        )
        return {"success": True, "dataset": result}
    except Exception as exc:
        raise _map_error(exc)


@router.get("/{dataset_id}/download")
def managed_dataset_download(
    dataset_id: str,
    version_id: str | None = None,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        data, metadata = download_managed_dataset(
            workspace_id=_workspace(workspace_id),
            token=_token(authorization),
            dataset_id=dataset_id,
            version_id=version_id,
        )
        return Response(
            content=data,
            media_type=metadata.get("content_type") or "application/octet-stream",
            headers={
                "Content-Disposition": f'attachment; filename="{metadata.get("original_filename", "dataset.bin")}"',
                "X-InsightFlow-Dataset-ID": dataset_id,
                "X-InsightFlow-Version": str(metadata.get("version_id", version_id or "")),
            },
        )
    except Exception as exc:
        raise _map_error(exc)


@router.post("/{dataset_id}/working-copies")
def managed_working_copy(
    dataset_id: str,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return {"success": True, "working_copy": create_managed_working_copy(
            workspace_id=_workspace(workspace_id),
            token=_token(authorization),
            dataset_id=dataset_id,
        )}
    except Exception as exc:
        raise _map_error(exc)


@router.delete("/{dataset_id}")
def managed_dataset_delete(
    dataset_id: str,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return delete_managed_dataset(
            workspace_id=_workspace(workspace_id),
            token=_token(authorization),
            dataset_id=dataset_id,
        )
    except Exception as exc:
        raise _map_error(exc)
