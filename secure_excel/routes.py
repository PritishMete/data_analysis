"""FastAPI routes for the secure Excel path and shared local meta/help routing."""

from __future__ import annotations

from fastapi import APIRouter, File, Form, UploadFile

from .service import execute_query, list_supported_transforms, load_excel_session, interpret_query
from common.assistant_identity import assistant_meta_or_not_handled
from common.conversation_state import STORE, build_session_summary, generate_suggestions
from common.detail_analysis import analyze_dataset_collection, load_dataset_tables


# Keep legacy /excel/* URLs stable while also exposing surface-neutral
# meta/session endpoints that Excel and Detail Analysis can share.
router = APIRouter(tags=["secure-excel"])


@router.get("/excel/ping")
def ping() -> dict[str, str]:
    return {"status": "ok", "mode": "secure-excel"}


@router.post("/v1/assistant/meta")
@router.post("/excel/meta")
async def assistant_meta(text: str = Form(...), surface: str = Form("detail_analysis")):
    """Resolve static InsightFlow identity/help questions locally, with no dataset/session."""
    return assistant_meta_or_not_handled(text, surface=surface)


@router.post("/v1/conversation/state/update")
async def conversation_state_update(payload: dict):
    session_id = str(payload.get("session_id") or "").strip()
    if not session_id:
        return {"success": False, "error": "session_id is required"}
    update = payload.get("update") if isinstance(payload.get("update"), dict) else {}
    state = STORE.record_success(session_id, update)
    return {"success": True, "state": state.to_dict()}


@router.post("/v1/conversation/suggestions")
async def conversation_suggestions(payload: dict):
    session_id = str(payload.get("session_id") or "").strip()
    if not session_id:
        return {"success": False, "error": "session_id is required", "suggestions": []}
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    limit = payload.get("limit", 5)
    try:
        suggestions = generate_suggestions(session_id, context=context, limit=int(limit))
    except (TypeError, ValueError):
        suggestions = generate_suggestions(session_id, context=context, limit=5)
    return {
        "success": True,
        "response_type": "suggested_next_questions",
        "suggestions": suggestions,
        "privacy": {"local_state_only": True, "external_ai_used": False},
    }


@router.get("/v1/conversation/state/{session_id}")
async def conversation_state(session_id: str):
    return {"success": True, "state": STORE.get(session_id).to_dict()}


@router.get("/v1/conversation/summary/{session_id}")
async def conversation_summary(session_id: str):
    return build_session_summary(session_id)


@router.post("/v1/conversation/reset/{session_id}")
async def conversation_reset(session_id: str):
    state = STORE.reset_active_scope(session_id)
    return {"success": True, "state": state.to_dict()}


@router.post("/v1/conversation/transaction/{session_id}/snapshot")
async def conversation_snapshot(session_id: str):
    snapshot = STORE.snapshot(session_id)
    return {"success": True, "snapshot": snapshot.to_dict()}


@router.post("/v1/conversation/transaction/{session_id}/restore")
async def conversation_restore(session_id: str, payload: dict):
    snapshot = payload.get("snapshot") if isinstance(payload.get("snapshot"), dict) else None
    if snapshot is None:
        return {"success": False, "error": "snapshot is required"}
    # Rehydrate only the bounded structured state; no dataset contents are stored here.
    current = STORE.get(session_id)
    for key, value in snapshot.items():
        if key == "session_id" or not hasattr(current, key):
            continue
        setattr(current, key, value)
    current.session_id = session_id
    STORE._states[session_id] = current
    return {"success": True, "state": current.to_dict()}


@router.post("/excel/session")
async def create_session(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    raw = await file.read()
    result = load_excel_session(
        raw,
        file.filename or "workbook.xlsx",
        sheet_name=sheet_name,
        active_cell=active_cell,
        dataset_range=dataset_range,
    )
    if result.get("session_id"):
        STORE.get(str(result["session_id"]))
    return result


@router.post("/excel/query")
async def query(session_id: str | None = Form(None), text: str = Form(...)):
    # Meta questions remain side conversations and intentionally do not mutate
    # the analytical state. Analytical Excel queries are recorded only after
    # a successful execution, so a failed query leaves prior context untouched.
    result = execute_query(session_id, text)
    if session_id and result.get("response_type") != "assistant_meta" and result.get("success", True):
        operation = result.get("query", {}).get("operation") if isinstance(result.get("query"), dict) else None
        STORE.record_success(str(session_id), {
            "query": text,
            "analysis": {"type": operation or "excel_query", "scope": "excel", "summary": result.get("message")},
            "result": {key: result.get(key) for key in ("row_count", "count", "message") if result.get(key) is not None},
        })
    return result


@router.post("/excel/detail-analysis")
async def detail_analysis(file: UploadFile = File(...)):
    """Analyze every non-empty worksheet in one workbook together."""
    raw = await file.read()
    try:
        tables = load_dataset_tables(raw, file.filename or "workbook.xlsx")
        return {"success": True, **analyze_dataset_collection(tables), "source_platform": "excel"}
    except Exception as exc:
        return {"success": False, "error": str(exc)}


@router.post("/excel/interpret")
async def interpret(session_id: str | None = Form(None), text: str = Form(...)):
    return interpret_query(session_id, text)


@router.get("/excel/transform/list")
def transform_list():
    return list_supported_transforms()


@router.get("/excel/powerbi/ping")
def powerbi_ping():
    return {"status": "ok", "powerbi": "unmodified"}


@router.get("/excel/powerbi/transform/list")
def powerbi_transform_list():
    return list_supported_transforms()
