from __future__ import annotations

import csv
import io
import os
import re
import uuid

import pandas as pd
from typing import Any, BinaryIO, Iterator

from sqlalchemy import delete, select, text

from firebase_authz.service import AuthenticationRequired, AuthzError, PermissionDenied, require_email_verified, verify_id_token
from firebase_authz.supabase_provider import (
    audit_dataset_event,
    authorization_context,
    authorize,
    authorize_dataset_upload_scope,
    authorize_dataset,
    authorize_working_copy,
    create_working_copy,
    delete_dataset_authorization,
    register_dataset,
    revoke_dataset_working_copies,
)
from datasets.models import DatasetColumn, DatasetRow
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
    raw_name = str(filename or "").strip()
    if "/" in raw_name or "\\" in raw_name:
        raise ValueError("Unsafe dataset filename.")
    name = os.path.basename(raw_name)
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


def _safe_dataset_name(dataset_name: str | None, filename: str) -> str:
    name = str(dataset_name or "").strip()
    if not name:
        name = os.path.splitext(filename)[0].strip()
    if (
        not name
        or len(name) > 255
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
    ):
        raise ValueError("Dataset name must be between 1 and 255 printable characters.")
    return name


def _claims(token: str) -> dict[str, Any]:
    return require_email_verified(verify_id_token(token))


def _authorization_context(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    context = authorization_context(claims, workspace_id)
    if not context.get("workspace_authorized"):
        raise PermissionDenied("User is not an active member of this workspace.")
    return context



def _authorize_upload(
    claims: dict[str, Any],
    workspace_id: str,
    *,
    location_id: str | None = None,
) -> dict[str, Any]:
    """Authorize original writes for Owner/BH or a Manager with a live branch grant.

    The shared scope check validates the current Manager grant, exact branch
    assignment and active membership. A per-dataset ACL cannot grant upload.
    """
    context = _authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"organization_owner", "branch_head", "manager"}):
        raise AuthzError(
            "Only an Organization Owner, assigned Branch Head, or explicitly "
            "authorized Manager may write an original dataset."
        )
    return authorize_dataset_upload_scope(
        claims, workspace_id, location_id=location_id
    )


def _authorize_delete(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    return authorize(claims, workspace_id, "dataset.delete")


def _authorize_dataset(
    claims: dict[str, Any], workspace_id: str, dataset_id: str, action: str
):
    # Every managed-dataset operation must resolve the dataset resource itself.
    # Do not short-circuit owners/managers through workspace-only permission
    # checks: the managed dataset is the resource boundary for profile, rows,
    # download, and working-copy operations.
    _authorization_context(claims, workspace_id)
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
    roles = set(context.get("role_ids", []))
    privileged = bool(roles.intersection({"organization_owner", "branch_head", "manager", "external_viewer"}))
    action = "dataset.view_original" if privileged else "dataset.create_working_copy"
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        result = []
        for dataset in repo.list_by_organization(organization_id, limit=100):
            if dataset.status == "deleted":
                continue
            try:
                scope = _authorize_dataset(claims, workspace_id, dataset.dataset_id, action)
            except AuthzError:
                continue
            if privileged:
                result.append(_structured_summary(dataset, len(repo.list_versions(dataset.dataset_id))))
            else:
                # Lower roles see only enough metadata to select a specific
                # authorized copy source. Never expose original version IDs,
                # row previews, schema, or version counts in their source list.
                result.append({
                    "dataset_id": dataset.dataset_id,
                    "display_name": dataset.dataset_name or dataset.original_filename or dataset.dataset_id,
                    "dataset_name": dataset.dataset_name or dataset.original_filename or dataset.dataset_id,
                    "location_id": str(scope.get("location_id")) if scope.get("location_id") is not None else None,
                    "access_mode": "copy_only",
                })
        return result
    finally:
        repo.db.close()


def get_managed_dataset(
    *, workspace_id: str, token: str, dataset_id: str
) -> dict[str, Any]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        organization_id = str(context["organization_id"])
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("Dataset not found.")
        return _structured_summary(dataset, len(repo.list_versions(dataset_id)))
    finally:
        repo.db.close()


def get_managed_dataset_profile(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str,
    version_id: str | None,
    preview_limit: int = 5,
) -> dict[str, Any]:
    """Return authorized persisted metadata and a small preview for DataScreen.

    The analytical rows remain server-side. This endpoint exposes only schema,
    profiling counters, and a bounded preview so the managed DataScreen can
    initialize its existing analysis UI without downloading the full dataset.
    """
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        organization_id = str(context["organization_id"])
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("Dataset not found.")
        version = repo.get_version(dataset_id, version_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("Dataset version not found.")
        columns = repo.get_columns_for_version(version.version_pk)
        rows = repo.get_rows(
            version.version_pk,
            limit=min(max(1, preview_limit), 20),
            offset=0,
        )
        ordered_names = [column.column_name for column in columns]
        column_stats = [
            {
                "column_name": column.column_name,
                "detected_type": column.detected_type,
                "nullable": column.nullable,
                "unique_count": column.unique_count,
                "missing_count": column.missing_count,
                "missing_percentage": column.missing_percentage,
                "inferred_role": column.inferred_role,
                "inferred_role_confidence": column.inferred_role_confidence,
            }
            for column in columns
        ]
        return {
            **_structured_summary(dataset, len(repo.list_versions(dataset_id))),
            "version_id": version.version_id,
            "version_status": version.status,
            "schema": column_stats,
            "column_names": ordered_names,
            "missing_values": {
                item["column_name"]: item["missing_count"] for item in column_stats
            },
            "unique_values": {
                item["column_name"]: item["unique_count"] for item in column_stats
            },
            "preview": [
                [
                    (
                        row["row_data"] if isinstance(row, dict) else row.row_data
                    ).get(name)
                    for name in ordered_names
                ]
                for row in rows
            ],
            "info": "Managed dataset profile loaded from Supabase PostgreSQL; full rows remain server-side.",
        }
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
    context = _authorization_context(claims, workspace_id)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        organization_id = str(context["organization_id"])
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
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
            "rows": rows,
        }
    finally:
        repo.db.close()


def get_working_copy_profile(
    *,
    workspace_id: str,
    token: str,
    working_copy_id: str,
    preview_limit: int = 5,
) -> dict[str, Any]:
    """Read a pinned snapshot through a working-copy grant, not by source ID."""
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    copy_context = authorize_working_copy(
        claims, workspace_id, working_copy_id, "working_copy.view"
    )
    source_dataset_id = str(copy_context["source_dataset_id"])
    source_version_id = str(copy_context["source_version"])
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(source_dataset_id)
        organization_id = str(context["organization_id"])
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("The working-copy source is no longer available.")
        version = repo.get_version(source_dataset_id, source_version_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("The authorized working-copy version is no longer available.")
        columns = repo.get_columns_for_version(version.version_pk)
        names = [column.column_name for column in columns]
        column_stats = [
            {
                "column_name": column.column_name,
                "detected_type": column.detected_type,
                "nullable": column.nullable,
                "unique_count": column.unique_count,
                "missing_count": column.missing_count,
                "missing_percentage": column.missing_percentage,
                "inferred_role": column.inferred_role,
                "inferred_role_confidence": column.inferred_role_confidence,
            }
            for column in columns
        ]
        rows = repo.get_rows(
            version.version_pk,
            limit=min(max(1, preview_limit), 20),
            offset=0,
        )
        return {
            "working_copy_id": working_copy_id,
            "access_mode": "working_copy",
            "dataset_name": dataset.dataset_name or dataset.original_filename or "Authorized copy",
            "row_count": version.row_count,
            "column_count": version.column_count,
            "version_status": version.status,
            "schema": column_stats,
            "column_names": names,
            "missing_values": {
                item["column_name"]: item["missing_count"] for item in column_stats
            },
            "unique_values": {
                item["column_name"]: item["unique_count"] for item in column_stats
            },
            "preview": [
                [
                    (row["row_data"] if isinstance(row, dict) else row.row_data).get(name)
                    for name in names
                ]
                for row in rows
            ],
        }
    finally:
        repo.db.close()


def get_working_copy_rows(
    *,
    workspace_id: str,
    token: str,
    working_copy_id: str,
    limit: int = 1000,
    offset: int = 0,
) -> dict[str, Any]:
    """Read rows from the immutable version pinned to an authorized working copy."""
    claims = _claims(token)
    copy_context = authorize_working_copy(
        claims, workspace_id, working_copy_id, "working_copy.view"
    )
    source_dataset_id = str(copy_context["source_dataset_id"])
    source_version_id = str(copy_context["source_version"])
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        dataset = repo.get_by_id(source_dataset_id)
        if dataset is None or dataset.organization_id != str(copy_context["organization_id"]):
            raise FileNotFoundError("The working-copy source is no longer available.")
        version = repo.get_version(source_dataset_id, source_version_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("The authorized working-copy version is no longer available.")
        rows = repo.get_rows(version.version_pk, limit=min(max(1, limit), 10000), offset=max(0, offset))
        return {
            "working_copy_id": working_copy_id,
            "access_mode": "working_copy",
            "row_count": version.row_count,
            "column_count": version.column_count,
            "offset": max(0, offset),
            "limit": min(max(1, limit), 10000),
            "rows": rows,
        }
    finally:
        repo.db.close()


def load_managed_dataset_dataframe(
    *,
    workspace_id: str,
    token: str,
    dataset_id: str | None = None,
    version_id: str | None = None,
    working_copy_id: str | None = None,
) -> pd.DataFrame:
    """Materialize one authorized managed version for an analysis request.

    Ingestion remains chunked/bulk. This materialization is deliberately kept
    on the backend so a managed 500k-row dataset is never copied into the
    browser just to run a remote analytical query.
    """
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    if working_copy_id:
        # Resolve source and pinned version exclusively server-side. The client
        # cannot convert a copy request into a direct original read by choosing
        # an original dataset ID or newer version.
        copy_context = authorize_working_copy(
            claims, workspace_id, working_copy_id, "working_copy.view"
        )
        dataset_id = str(copy_context["source_dataset_id"])
        version_id = str(copy_context["source_version"])
    else:
        if not dataset_id:
            raise ValueError("A managed dataset or authorized working copy is required.")
        _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    try:
        organization_id = str(context["organization_id"])
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id:
            raise FileNotFoundError("Dataset not found.")
        version = repo.get_version(dataset_id, version_id)
        if version is None or version.status != "ready":
            raise FileNotFoundError("Dataset version not found.")
        columns = repo.get_columns_for_version(version.version_pk)
        names = [column.column_name for column in columns]
        physical = repo.iter_physical_rows(
            version.version_pk,
            batch_size=5000,
        )
        rows = [
            [item["row_data"].get(name) for name in names]
            for item in physical
        ]
        return pd.DataFrame.from_records(rows, columns=names)
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
    context = _authorization_context(claims, workspace_id)
    _authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    from core.db import SessionLocal

    repo = DatasetRepository(SessionLocal())
    organization_id = str(context["organization_id"])
    dataset = repo.get_by_id(dataset_id)
    if dataset is None or dataset.organization_id != organization_id:
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

            for item in repo.iter_physical_rows(
                version.version_pk,
                batch_size=5000,
            ):
                line = io.StringIO()
                writer = csv.writer(line, lineterminator="\\r\\n")
                writer.writerow([
                    "" if item["row_data"].get(column.column_name) is None
                    else item["row_data"].get(column.column_name)
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


def _register_authorization(
    claims: dict[str, Any],
    workspace_id: str,
    dataset_id: str,
    location_id: str | None = None,
) -> None:
    register_dataset(
        claims,
        workspace_id,
        dataset_id,
        str(claims["uid"]),
        True,
        location_id=location_id,
    )


def _unregister_authorization(workspace_id: str, dataset_id: str) -> None:
    try:
        delete_dataset_authorization(workspace_id, dataset_id)
    except Exception:
        pass


def _mark_failed_sql_version(
    repo: DatasetRepository,
    dataset_id: str,
    version_id: str,
    was_new_dataset: bool,
    reason: str,
) -> None:
    # Preserve the explicit FAILED lifecycle state for audit/retry visibility,
    # but remove every structured row/column so the failed version is never
    # usable as an analytical dataset. Existing READY versions are untouched.
    with repo.db.begin():
        dataset = repo.get_by_id(dataset_id)
        version = repo.get_version(dataset_id, version_id)
        if version is not None:
            if version.data_table_name:
                from datasets.physical_table import drop_physical_table
                drop_physical_table(repo.db.connection(), version.data_table_name)
                version.data_table_name = None
            repo.db.execute(
                delete(DatasetRow).where(DatasetRow.version_pk == version.version_pk)
            )
            repo.db.execute(
                delete(DatasetColumn).where(
                    DatasetColumn.version_pk == version.version_pk
                )
            )
            version.status = "failed"
            version.failure_reason = str(reason)[:1000]
            version.row_count = 0
            version.column_count = 0
        if dataset is not None and was_new_dataset:
            dataset.status = "failed"
            dataset.current_version_id = None
            dataset.row_count = 0
            dataset.column_count = 0
            dataset.schema_hash = ""
        repo.db.flush()


def _discard_sql_registration(
    repo: DatasetRepository,
    dataset_id: str,
    version_id: str,
    was_new_dataset: bool,
) -> None:
    """Remove unfinalized SQL data when the upload's final auth check fails."""
    with repo.db.begin():
        if was_new_dataset:
            repo.delete_dataset(dataset_id, commit=False)
            return

        version = repo.get_version(dataset_id, version_id)
        if version is None:
            return
        if version.data_table_name:
            from datasets.physical_table import drop_physical_table

            drop_physical_table(repo.db.connection(), version.data_table_name)
            version.data_table_name = None
        repo.db.execute(
            delete(DatasetRow).where(DatasetRow.version_pk == version.version_pk)
        )
        repo.db.execute(
            delete(DatasetColumn).where(DatasetColumn.version_pk == version.version_pk)
        )
        repo.db.delete(version)
        repo.db.flush()



def _lock_active_upload_assignment(
    repo: DatasetRepository,
    context: dict[str, Any],
) -> None:
    """Lock the exact upload authority through the version commit."""
    role = str(context.get("upload_role_id") or "")
    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    principal = str(context["principal_id"])
    location = str(context["location_id"])

    if role == "organization_owner":
        assignment = repo.db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            JOIN member_roles mr
              ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
             AND mr.role_id='organization_owner'
            JOIN role_permissions rp
              ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
            JOIN locations l ON l.organization_id=oa.organization_id
              AND l.location_id=:location AND l.status='active'
            WHERE oa.organization_id=:org AND oa.principal_id=:principal
              AND oa.role_id='organization_owner' AND oa.status='active'
              AND m.workspace_id=:workspace AND m.status='active'
            ORDER BY oa.assignment_id LIMIT 1
            FOR SHARE OF oa, m, mr, rp, l
        """), {"org":org,"workspace":workspace,"principal":principal,"location":location}).scalar_one_or_none()
    elif role == "branch_head":
        assignment = repo.db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            JOIN member_roles mr
              ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
             AND mr.role_id='branch_head'
            JOIN role_permissions rp
              ON rp.role_id=oa.role_id AND rp.permission_id='dataset.upload'
            JOIN locations l ON l.organization_id=oa.organization_id
              AND l.location_id=oa.location_id AND l.status='active'
            WHERE oa.organization_id=:org AND oa.principal_id=:principal
              AND oa.location_id=:location AND oa.role_id='branch_head'
              AND oa.status='active' AND m.workspace_id=:workspace AND m.status='active'
            ORDER BY oa.assignment_id LIMIT 1
            FOR SHARE OF oa, m, mr, rp, l
        """), {"org":org,"workspace":workspace,"principal":principal,"location":location}).scalar_one_or_none()
    elif role == "manager":
        assignment = repo.db.execute(text("""
            SELECT g.grant_id
            FROM manager_dataset_upload_grants g
            JOIN organizational_assignments oa
              ON oa.organization_id=g.organization_id
             AND oa.principal_id=g.manager_principal_id
             AND oa.location_id=g.location_id
             AND oa.role_id='manager' AND oa.status='active'
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
             AND m.workspace_id=g.workspace_id AND m.status='active'
            JOIN member_roles mr
              ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
             AND mr.role_id='manager'
            JOIN identity_bindings ib
              ON ib.principal_id=m.principal_id AND ib.status='active'
             AND ib.provider='supabase' AND ib.provider_subject=:subject
            JOIN locations l
              ON l.organization_id=g.organization_id AND l.location_id=g.location_id
             AND l.status='active'
            WHERE g.organization_id=:org AND g.workspace_id=:workspace
              AND g.manager_principal_id=:principal AND g.location_id=:location
              AND g.revoked_at IS NULL
            LIMIT 1
            FOR SHARE OF g, oa, m, mr, ib, l
        """), {
            "org": org, "workspace": workspace, "principal": principal,
            "location": location, "subject": str(context.get("_identity_subject") or ""),
        }).scalar_one_or_none()
    else:
        raise AuthzError("The active role is not authorized to write an original dataset.")

    if assignment is None:
        raise AuthzError("The upload role or active branch assignment is no longer valid.")



def upload_managed_dataset_stream(
    *,
    workspace_id: str,
    token: str,
    filename: str,
    stream: BinaryIO,
    content_type: str | None,
    dataset_name: str | None = None,
    provider: SupabaseDatasetStorageProvider | None = None,
    dataset_id: str | None = None,
    location_id: str | None = None,
) -> dict[str, Any]:
    claims = _claims(token)
    if dataset_id is not None:
        # Resolve branch scope from the authoritative source ACL, not request body.
        dataset_scope = _authorize_dataset(
            claims, workspace_id, dataset_id, "dataset.upload"
        )
        context = _authorize_upload(
            claims, workspace_id, location_id=str(dataset_scope.get("location_id") or "")
        )
    else:
        context = _authorize_upload(claims, workspace_id, location_id=location_id)

    safe_name = _safe_filename(filename)
    safe_dataset_name = _safe_dataset_name(dataset_name, safe_name)
    organization_id = str(context["organization_id"])
    from core.db import SessionLocal
    repo = DatasetRepository(SessionLocal())
    registry = DatasetRegistryService(repo)
    registration = None
    stored = None
    new_dataset = dataset_id is None
    provider = provider or SupabaseDatasetStorageProvider()
    base_version_id = None
    try:
        if dataset_id is not None:
            current_dataset = repo.get_by_id(dataset_id)
            if current_dataset is None or current_dataset.organization_id != organization_id:
                raise FileNotFoundError("Dataset not found.")
            base_version_id = current_dataset.current_version_id
        registration = registry.register_csv_stream(
            file_obj=stream,
            filename=safe_name,
            organization_id=organization_id,
            dataset_name=(
                safe_dataset_name if dataset_id is None
                else str(current_dataset.dataset_name or safe_dataset_name)
            ),
            uploaded_by=str(context.get("principal_id") or claims["uid"]),
            existing_dataset_id=dataset_id,
            content_type=content_type or "text/csv",
            max_bytes=MAX_DATASET_BYTES,
        )
        if registration.registration.was_duplicate:
            _audit_safely(
                workspace_id, str(claims["uid"]), "dataset.upload", "duplicate",
                resource_id=registration.registration.dataset.dataset_id,
                metadata={"version_id": registration.version.version_id},
            )
            return _structured_summary(
                registration.registration.dataset,
                len(repo.list_versions(registration.registration.dataset.dataset_id)),
            )

        if new_dataset:
            _register_authorization(
                claims, workspace_id, registration.registration.dataset.dataset_id,
                str(context["location_id"]),
            )
        if not registration.sample.empty:
            intelligence = SchemaIntelligenceService(repo, RelationshipRepository(repo.db))
            intelligence.analyze_dataset(
                registration.registration.dataset.dataset_id,
                registration.sample,
                version_pk=registration.version.version_pk,
            )

        if dataset_id is not None:
            repo.db.execute(text("""
                SELECT dataset_id FROM datasets
                WHERE dataset_id=:dataset AND organization_id=:org
                FOR UPDATE
            """), {"dataset": dataset_id, "org": organization_id}).scalar_one_or_none()
            current_scope = repo.db.execute(text("""
                SELECT location_id, status, protected_original
                FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:dataset
                FOR SHARE
            """), {"org": organization_id, "dataset": dataset_id}).mappings().first()
            if (current_scope is None or current_scope["status"] != "active"
                    or not current_scope["protected_original"]
                    or str(current_scope["location_id"] or "") != str(context["location_id"])):
                raise AuthzError("The original dataset branch assignment changed during upload.")

        _lock_active_upload_assignment(repo, context)
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
            expected_current_version_id=(base_version_id if not new_dataset else None),
        )
        _audit_safely(
            workspace_id, str(claims["uid"]),
            "dataset.upload" if new_dataset else "dataset.version_upload",
            "succeeded", resource_id=dataset.dataset_id,
            metadata={"version_id": registration.version.version_id,
                      "row_count": dataset.row_count, "column_count": dataset.column_count,
                      "storage_mode": "sql_structured"},
        )
        return _structured_summary(dataset, len(repo.list_versions(dataset.dataset_id)))
    except Exception as exc:
        repo.db.rollback()
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
                if isinstance(exc, (AuthzError, PermissionDenied)):
                    _discard_sql_registration(
                        repo, registration.registration.dataset.dataset_id,
                        registration.version.version_id, new_dataset,
                    )
                else:
                    _mark_failed_sql_version(
                        repo, registration.registration.dataset.dataset_id,
                        registration.version.version_id, new_dataset, str(exc),
                    )
            except Exception:
                pass
            if new_dataset:
                _unregister_authorization(workspace_id, registration.registration.dataset.dataset_id)
        _audit_safely(
            workspace_id, str(claims["uid"]),
            "dataset.upload" if new_dataset else "dataset.version_upload",
            "failed", resource_id=dataset_id,
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
    context = _authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if "branch_head" not in set(context.get("role_ids", [])) and "organization_owner" not in set(context.get("role_ids", [])):
        raise PermissionDenied("Only an Organization Owner or Branch Head may delete an original dataset.")
    dataset_scope = _authorize_dataset(claims, workspace_id, dataset_id, "dataset.delete")
    location_id = str(dataset_scope.get("location_id") or "")
    if not location_id:
        raise PermissionDenied("Original dataset deletion requires an active branch assignment.")
    # Owner is organization-wide; Branch Head remains constrained to the branch.
    authorize_dataset_upload_scope(claims, workspace_id, location_id=location_id)
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
                provider.delete(organization_id=organization_id, dataset_id=dataset_id, version_id=version.version_id)
        revoke_dataset_working_copies(workspace_id, dataset_id)
        repo.delete_dataset(dataset_id)
        _unregister_authorization(workspace_id, dataset_id)
        _audit_safely(workspace_id, str(claims["uid"]), "dataset.delete", "succeeded", resource_id=dataset_id)
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
        # Copy-only roles must not receive original dataset/version identifiers.
        roles = set(context.get("role_ids", []))
        result = {
            key: value for key, value in metadata.items()
            if key not in {"source_dataset_id", "source_version",
                           "structured_dataset_id", "structured_version_id"}
        }
        result["access_mode"] = "working_copy"
        if roles.intersection({"organization_owner", "branch_head", "manager"}):
            result.update({
                "structured_dataset_id": dataset_id,
                "structured_version_id": version.version_id,
            })
        return result
    finally:
        repo.db.close()
