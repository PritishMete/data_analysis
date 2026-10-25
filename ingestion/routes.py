# ingestion/routes.py
# ─────────────────────────────────────────────────────────────────────────────
# The single new "smart upload" endpoint. This is ADDITIVE — it does not
# replace /clean_data, /agentic_clean_data, or /smart_query in main.py; it
# sits alongside them. Existing endpoints keep working exactly as they do
# today. See INTEGRATION.md for the optional, minimal hook to also call this
# from inside an existing upload endpoint if/when you want automatic
# registration on every upload rather than only via this dedicated route.
# ─────────────────────────────────────────────────────────────────────────────

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile
from pydantic import BaseModel
from sqlalchemy.orm import Session

from common.file_parsing import read_file_to_dataframe
from core.db import get_db
from datasets.repository import DatasetRepository
from datasets.routes import get_dataset_repository
from datasets.schemas import DatasetColumnOut, DatasetOut
from datasets.service import DatasetRegistryService
from schema_intelligence.repository import ColumnRoleDetectionRepository, DuplicateColumnRepository, RelationshipRepository
from schema_intelligence.routes import get_column_detection_repository, get_duplicate_repository, get_relationship_repository
from schema_intelligence.service import SchemaIntelligenceService

from .service import DatasetIngestionOrchestrator
from dataset_storage.routes import _token, _workspace
from dataset_storage.service import (
    MAX_DATASET_BYTES,
    _authorize_dataset,
    _authorize_upload,
    _register_authorization,
    _audit_safely,
    _safe_filename,
)
from firebase_authz.service import AuthzError, AuthenticationRequired, PermissionDenied, require_email_verified, verify_id_token
from firebase_authz.supabase_provider import authorization_context

ingestion_router = APIRouter(prefix="/v2/ingest", tags=["ingestion"])


def get_registry_service(repo: DatasetRepository = Depends(get_dataset_repository)) -> DatasetRegistryService:
    return DatasetRegistryService(repo)


def get_intelligence_service(
    dataset_repo: DatasetRepository = Depends(get_dataset_repository),
    relationship_repo: RelationshipRepository = Depends(get_relationship_repository),
    column_detection_repo: ColumnRoleDetectionRepository = Depends(get_column_detection_repository),
    duplicate_repo: DuplicateColumnRepository = Depends(get_duplicate_repository),
) -> SchemaIntelligenceService:
    return SchemaIntelligenceService(dataset_repo, relationship_repo, column_detection_repo, duplicate_repo)


def get_orchestrator(
    registry_service: DatasetRegistryService = Depends(get_registry_service),
    intelligence_service: SchemaIntelligenceService = Depends(get_intelligence_service),
) -> DatasetIngestionOrchestrator:
    return DatasetIngestionOrchestrator(registry_service, intelligence_service)


class RelationshipCandidateOut(BaseModel):
    source_column: str
    target_dataset_id: str
    target_column: str
    confidence: float


class IngestResponse(BaseModel):
    dataset: DatasetOut
    columns: list[DatasetColumnOut]
    was_duplicate: bool
    relationships: list[RelationshipCandidateOut]


@ingestion_router.post("/dataset", response_model=IngestResponse)
async def ingest_dataset(
    file: UploadFile = File(...),
    organization_id: str = Form(...),
    dataset_name: str | None = Form(None),
    uploaded_by: str | None = Form(None),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
    db: Session = Depends(get_db),
    orchestrator: DatasetIngestionOrchestrator = Depends(get_orchestrator),
):
    # This legacy ingestion endpoint also creates READY registry versions. Keep it
    # behind the same server-side Branch Head gate as managed-dataset uploads.
    try:
        token = _token(authorization)
        claims = require_email_verified(verify_id_token(token))
        resolved_workspace = _workspace(workspace_id, authorization)
        context = authorization_context(claims, resolved_workspace)
        if not context.get("workspace_authorized"):
            raise PermissionDenied("Workspace authorization denied.")
        upload_scope = _authorize_upload(claims, resolved_workspace)
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc)) from exc
    except AuthzError as exc:
        raise HTTPException(403, str(exc)) from exc
    if organization_id and str(organization_id) != str(context["organization_id"]):
        raise HTTPException(403, "The supplied organization does not match the authenticated workspace.")
    try:
        filename = _safe_filename(file.filename or "upload.csv")
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    raw_bytes = await file.read(MAX_DATASET_BYTES + 1)
    if len(raw_bytes) > MAX_DATASET_BYTES:
        raise HTTPException(413, "Dataset file exceeds the configured upload limit.")
    df = read_file_to_dataframe(filename, raw_bytes)
    result = orchestrator.ingest(
        df=df,
        raw_bytes=raw_bytes,
        organization_id=str(context["organization_id"]),
        dataset_name=dataset_name or filename,
        uploaded_by=str(context["principal_id"]),
        source_type="csv",
    )
    dataset_id = result.registration.dataset.dataset_id
    if result.registration.was_duplicate:
        try:
            scope = _authorize_dataset(claims, resolved_workspace, dataset_id, "dataset.view_original")
            if str(scope.get("location_id") or "") != str(upload_scope["location_id"]):
                raise PermissionDenied("The existing dataset belongs to a different branch.")
        except AuthzError as exc:
            raise HTTPException(403, "An existing dataset cannot be re-registered into another branch.") from exc
    else:
        try:
            _register_authorization(claims, resolved_workspace, dataset_id, str(upload_scope["location_id"]))
        except Exception:
            # Registry ingestion commits internally; remove a newly-created
            # orphan if its authorization record cannot be committed.
            try:
                db.delete(result.registration.dataset)
                db.commit()
            except Exception:
                db.rollback()
            raise
    _audit_safely(
        resolved_workspace,
        str(claims["uid"]),
        "dataset.upload",
        "duplicate" if result.registration.was_duplicate else "succeeded",
        resource_id=dataset_id,
        metadata={"source": "legacy_ingestion_route", "location_id": str(upload_scope["location_id"])},
    )

    columns_out = [
        DatasetColumnOut(
            column_name=c.column_name,
            detected_type=c.detected_type,
            nullable=c.nullable,
            unique_count=c.unique_count,
            missing_percentage=c.missing_percentage,
            inferred_role=result.column_roles.get(c.column_name, c.inferred_role),
        )
        for c in result.registration.columns
    ]

    return IngestResponse(
        dataset=result.registration.dataset,
        columns=columns_out,
        was_duplicate=result.registration.was_duplicate,
        relationships=[
            RelationshipCandidateOut(
                source_column=r.source_column,
                target_dataset_id=r.target_dataset_id,
                target_column=r.target_column,
                confidence=r.confidence,
            )
            for r in result.relationships
        ],
    )
