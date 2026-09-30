from __future__ import annotations

import logging

from fastapi import APIRouter, File, Header, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse

from firebase_authz.service import AuthzError, AuthenticationRequired, PermissionDenied, verify_id_token
from firebase_authz.supabase_provider import authorization_context
from .service import (
    create_managed_working_copy,
    delete_managed_dataset,
    stream_managed_dataset_csv,
    get_managed_dataset,
    get_managed_dataset_rows,
    get_managed_dataset_profile,
    list_authorized_datasets,
    upload_managed_dataset_stream,
)

router = APIRouter(prefix="/v1/managed-datasets", tags=["managed-datasets"])
logger = logging.getLogger(__name__)


def _token(value: str | None) -> str:
    if not value or not value.startswith("Bearer "):
        raise HTTPException(401, "Authentication required.")
    return value[7:].strip()


def _workspace(value: str | None, authorization: str | None = None) -> str:
    """Resolve an authenticated workspace; never trust a client-supplied ID by itself.

    The header is only a workspace selector. Authorization is still resolved from
    the bearer identity, and the selected workspace must be an active membership
    of that identity. If the cached header is stale/missing, recover the unique
    active workspace from the authoritative Supabase authorization context.
    """
    token = _token(authorization)
    claims = verify_id_token(token)
    normalized = (value or "").strip()

    if normalized:
        selected = authorization_context(claims, normalized)
        logger.info(
            "managed_dataset_workspace_resolution selected=%s authorized=%s principal=%s organization=%s",
            normalized,
            bool(selected.get("workspace_authorized")),
            selected.get("principal_id"),
            selected.get("organization_id"),
        )
        if selected.get("workspace_authorized"):
            return str(selected["workspace_id"]).strip()

    context = authorization_context(claims)
    workspaces = context.get("workspaces") or []
    logger.info(
        "managed_dataset_workspace_resolution fallback authorized=%s principal=%s organization=%s workspace_count=%s",
        bool(context.get("workspace_authorized")),
        context.get("principal_id"),
        context.get("organization_id"),
        len(workspaces),
    )
    active = [
        item for item in workspaces
        if isinstance(item, dict)
        and str(item.get("membership_status") or "").lower() == "active"
        and str(item.get("workspace_id") or "").strip()
    ]
    if len(active) == 1:
        return str(active[0]["workspace_id"]).strip()
    if not active:
        raise HTTPException(403, "Workspace authorization context required.")
    raise HTTPException(409, "Multiple workspace contexts are available; select a workspace.")


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


@router.get("")
def managed_dataset_list(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return {"datasets": list_authorized_datasets(
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization)
        )}
    except Exception as exc:
        raise _map_error(exc)


@router.get("/{dataset_id}")
def managed_dataset_detail(
    dataset_id: str,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return get_managed_dataset(
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization), dataset_id=dataset_id
        )
    except Exception as exc:
        raise _map_error(exc)


@router.get("/{dataset_id}/profile")
def managed_dataset_profile(
    dataset_id: str,
    version_id: str | None = Query(default=None),
    preview_limit: int = Query(default=5, ge=1, le=20),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return get_managed_dataset_profile(
            workspace_id=_workspace(workspace_id, authorization),
            token=_token(authorization),
            dataset_id=dataset_id,
            version_id=version_id,
            preview_limit=preview_limit,
        )
    except Exception as exc:
        raise _map_error(exc)


@router.get("/{dataset_id}/rows")
def managed_dataset_rows(
    dataset_id: str,
    version_id: str | None = Query(default=None),
    limit: int = Query(default=1000, ge=1, le=10000),
    offset: int = Query(default=0, ge=0),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        return get_managed_dataset_rows(
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization),
            dataset_id=dataset_id, version_id=version_id, limit=limit, offset=offset,
        )
    except Exception as exc:
        raise _map_error(exc)


@router.post("")
async def managed_dataset_upload(
    file: UploadFile = File(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        result = upload_managed_dataset_stream(
            workspace_id=_workspace(workspace_id, authorization),
            token=_token(authorization),
            filename=file.filename or "",
            stream=file.file,
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
        result = upload_managed_dataset_stream(
            workspace_id=_workspace(workspace_id, authorization),
            token=_token(authorization),
            filename=file.filename or "",
            stream=file.file,
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
        iterator, metadata = stream_managed_dataset_csv(
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization),
            dataset_id=dataset_id, version_id=version_id,
        )
        filename = metadata.get("original_filename") or "dataset.csv"
        if not str(filename).lower().endswith(".csv"):
            filename = f"{filename}.csv"
        return StreamingResponse(
            iterator,
            media_type="text/csv; charset=utf-8",
            headers={
                "Content-Disposition": f'attachment; filename="{filename}"',
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
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization), dataset_id=dataset_id,
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
            workspace_id=_workspace(workspace_id, authorization), token=_token(authorization), dataset_id=dataset_id,
        )
    except Exception as exc:
        raise _map_error(exc)
