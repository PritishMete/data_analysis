"""FastAPI routes for the secure Excel-only path."""

from __future__ import annotations

from fastapi import APIRouter, File, Form, UploadFile

from .service import execute_query, list_supported_transforms, load_excel_session, interpret_query
from common.detail_analysis import analyze_dataset_collection, load_dataset_tables


router = APIRouter(prefix="/excel", tags=["secure-excel"])


@router.get("/ping")
def ping() -> dict[str, str]:
    return {"status": "ok", "mode": "secure-excel"}


@router.post("/session")
async def create_session(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    raw = await file.read()
    return load_excel_session(
        raw,
        file.filename or "workbook.xlsx",
        sheet_name=sheet_name,
        active_cell=active_cell,
        dataset_range=dataset_range,
    )


@router.post("/query")
async def query(session_id: str = Form(...), text: str = Form(...)):
    return execute_query(session_id, text)


@router.post("/detail-analysis")
async def detail_analysis(file: UploadFile = File(...)):
    """Analyze every non-empty worksheet in one workbook together."""
    raw = await file.read()
    try:
        tables = load_dataset_tables(raw, file.filename or "workbook.xlsx")
        return {"success": True, **analyze_dataset_collection(tables), "source_platform": "excel"}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


@router.post("/interpret")
async def interpret(session_id: str = Form(...), text: str = Form(...)):
    return interpret_query(session_id, text)


@router.get("/transform/list")
def transform_list():
    return list_supported_transforms()


@router.get("/powerbi/ping")
def powerbi_ping():
    return {"status": "ok", "powerbi": "unmodified"}


@router.get("/powerbi/transform/list")
def powerbi_transform_list():
    return list_supported_transforms()
