from __future__ import annotations

import time
import traceback
import uuid
from typing import Any

import pandas as pd
from fastapi import APIRouter
from pydantic import BaseModel, Field

from data_cleaner import clean_dataframe
from common.analytics.profiling import analyze_dataframe
from common.json_safe import to_json_safe
from common.transformations import TransformationEngine, TransformationHistory
from ai_analyst import generate_report
from command_agent import parse_agentic_command
from query_router import handle_smart_query

router = APIRouter(prefix="/powerbi", tags=["Power BI"])

# Single shared engine instance — same TransformationEngine class the Excel
# /transform/* routes in main.py use (see common/transformations/). No
# separate/duplicate transformation logic is defined here.
_ENGINE = TransformationEngine()

# Process-local, in-memory session store: session_id -> {"history": ..., "df": ...}.
# Power BI never uploads a file, so this dict IS the "working dataset" the
# spec calls for. Same idle-eviction pattern main.py's own
# _TRANSFORMATION_HISTORIES uses, for the same reason (unbounded growth risk
# otherwise). This is a same-process stopgap: it does not survive multiple
# Render worker processes or a restart. Swap for Redis/Postgres-backed
# storage if the deployment ever runs >1 worker.
_SESSIONS: dict[str, dict[str, Any]] = {}
_SESSION_TTL = 2 * 60 * 60  # 2 hours idle


class DatasetPayload(BaseModel):
    columns: list[str] = Field(default_factory=list)
    rows: list[dict[str, Any]] = Field(default_factory=list)
    session_id: str | None = None


class SessionInitRequest(DatasetPayload):
    """Body for POST /powerbi/session. columns/rows are optional — a
    session can be created empty and populated by a later call that passes
    the same session_id."""
    pass


class PipelineRequest(DatasetPayload):
    transformation_name: str | None = None
    query: str | None = None
    params: dict[str, Any] | None = None
    value_column: str | None = None
    sample_rows: int = 15


class CleanRequest(DatasetPayload):
    config: dict[str, Any] = Field(default_factory=dict)


class QueryRequest(DatasetPayload):
    query: str
    available_sheets: list[str] = Field(default_factory=list)


class AgenticCommandRequest(BaseModel):
    text: str
    columns: list[str] = Field(default_factory=list)
    available_sheets: list[str] = Field(default_factory=list)
    session_id: str | None = None


# ── Diagnostics ──────────────────────────────────────────────────────────
# The visual needs to tell "backend unavailable / timeout / 404 / 400 / 500 /
# CORS / invalid request / transformation failure / unsupported operation"
# apart. FastAPI's own validation errors (missing/invalid fields -> 422) and
# the global 404 handler registered in main.py already produce this same
# {"success": false, "error": {...}} shape; every route below funnels its
# own failures through this helper so ALL /powerbi/* error bodies share one
# envelope, regardless of which route or which underlying engine raised.
def _error(error_type: str, message: str, endpoint: str, **extra: Any) -> dict[str, Any]:
    return {
        "success": False,
        "error": {"type": error_type, "message": message, "endpoint": endpoint, **extra},
    }


def _df(payload: DatasetPayload) -> pd.DataFrame:
    if payload.columns:
        df = pd.DataFrame(payload.rows, columns=payload.columns)
    else:
        df = pd.DataFrame(payload.rows)
    # Preserve the column order Power BI sent.
    if payload.columns:
        for col in payload.columns:
            if col not in df.columns:
                df[col] = None
        df = df[payload.columns]
    return df


def _json_df(df: pd.DataFrame, limit: int | None = None) -> dict[str, Any]:
    view = df if limit is None else df.head(limit)
    return {
        "columns": list(df.columns),
        "rows": to_json_safe(view.fillna("").to_dict(orient="records")),
        "row_count": int(len(df)),
        "preview_row_count": int(len(view)),
    }


def _evict_stale_sessions() -> None:
    now = time.time()
    stale = [k for k, v in _SESSIONS.items() if now - v.get("last_access", now) > _SESSION_TTL]
    for k in stale:
        _SESSIONS.pop(k, None)


def _session(session_id: str | None) -> tuple[str, dict[str, Any]]:
    _evict_stale_sessions()
    sid = session_id or str(uuid.uuid4())
    state = _SESSIONS.setdefault(sid, {"history": TransformationHistory(), "df": None})
    state["last_access"] = time.time()
    return sid, state


def _working_df(payload: DatasetPayload, state: dict[str, Any]) -> pd.DataFrame:
    """Rows sent on THIS request always take priority (Power BI resends its
    current DataView on most calls); otherwise fall back to whatever this
    session already has stored from a prior /session or /transform/apply
    call. This is what lets /transform/preview and /transform/apply be
    called with only a session_id once a session has a working dataset."""
    if payload.rows or payload.columns:
        return _df(payload)
    if state.get("df") is not None:
        return state["df"]
    return pd.DataFrame()


def _classify_transform_error(message: str | None) -> str:
    """Maps the shared TransformationEngine's error strings to the specific
    diagnostic types the Power BI visual needs to distinguish (per spec:
    invalid dataset / invalid transformation / unsupported transformation),
    instead of collapsing every engine failure into one generic type."""
    text = (message or "").lower()
    if "could not locate a matching transformation" in text:
        return "unsupported_transformation"
    if "could not evaluate this request against the transformation registry" in text:
        return "invalid_transformation"
    return "transformation_failed"


def _pipeline_result(result, state: dict[str, Any], sid: str) -> dict[str, Any]:
    if not result.success:
        return _error(
            _classify_transform_error(result.error), result.error or "Transformation failed.",
            "/powerbi/transform", session_id=sid, transformation=result.transformation,
        )
    if result.dataframe is not None:
        state["df"] = result.dataframe.copy()
    out = {
        "success": True,
        "session_id": sid,
        "transformation": result.transformation,
        "preview": result.preview,
        "metadata": result.metadata,
        "updated_schema": result.updated_schema,
        "updated_statistics": result.updated_statistics,
        "updated_kpis": result.updated_kpis,
        "updated_charts": result.updated_charts,
        "updated_ai_report": result.updated_ai_report,
        "execution_time": result.execution_time,
        "message": result.message,
        "history": state["history"].list(),
    }
    if state.get("df") is not None:
        out["export"] = _json_df(state["df"])
    return to_json_safe(out)


@router.get("/version")
def version():
    return {
        "service": "InsightFlow Power BI Backend",
        "version": "3.0.0",
        "source": "shared Excel analysis engine",
        "pipeline": True,
        "shared_engine": True,
        "routes": [
            "/powerbi/session",
            "/powerbi/profile",
            "/powerbi/analyze",
            "/powerbi/analyze-report",
            "/powerbi/clean",
            "/powerbi/transform/preview",
            "/powerbi/transform/apply",
            "/powerbi/transform/undo",
            "/powerbi/transform/redo",
            "/powerbi/transform/history/{session_id}",
            "/powerbi/transform/list",
            "/powerbi/smart_query",
            "/powerbi/agentic_command",
        ],
    }


@router.get("/ping")
def ping():
    return {"status": "awake", "service": "powerbi", "pipeline": True}


@router.get("/health")
def health():
    return {"status": "ok", "service": "InsightFlow Power BI Backend", "pipeline": True}


@router.post("/session")
def create_session(payload: SessionInitRequest):
    """Initializes (or re-initializes) the working dataset for a session_id.
    Power BI calls this once after the visual builds its DataView JSON; every
    later /powerbi/* call in the pipeline (clean/transform/query/...) can
    then be sent with just that session_id, or with a fresh rows payload to
    overwrite it."""
    sid, state = _session(payload.session_id)
    df = _df(payload) if (payload.rows or payload.columns) else pd.DataFrame()
    state["df"] = df
    state["history"] = TransformationHistory()
    return to_json_safe({
        "success": True,
        "session_id": sid,
        "profile": analyze_dataframe(df) if not df.empty else None,
        "data": _json_df(df, 15),
    })


@router.post("/profile")
def profile(payload: DatasetPayload):
    if not payload.rows and not payload.session_id:
        return _error("invalid_dataset", "No rows provided and no session_id to fall back on.", "/powerbi/profile")
    try:
        df = _df(payload) if payload.rows else _SESSIONS.get(payload.session_id, {}).get("df", pd.DataFrame())
        return to_json_safe({"success": True, "profile": analyze_dataframe(df), "data": _json_df(df, 15)})
    except Exception as e:
        traceback.print_exc()
        return _error("invalid_dataset", str(e), "/powerbi/profile")


@router.post("/analyze")
def analyze(payload: DatasetPayload):
    if not payload.rows and not payload.session_id:
        return _error("invalid_dataset", "No rows provided and no session_id to fall back on.", "/powerbi/analyze")
    try:
        df = _df(payload) if payload.rows else _SESSIONS.get(payload.session_id, {}).get("df", pd.DataFrame())
        return to_json_safe({"success": True, **analyze_dataframe(df)})
    except Exception as e:
        traceback.print_exc()
        return _error("invalid_dataset", str(e), "/powerbi/analyze")


@router.post("/analyze-report")
async def analyze_report(payload: DatasetPayload):
    """AI-narrated report, reusing the exact same ai_analyst.generate_report()
    the Excel /analyze-report route calls — the only difference is the
    DataFrame comes from a Power BI DataView JSON body instead of an
    uploaded file."""
    try:
        df = _df(payload)
        result = await generate_report(df)
        return to_json_safe({"success": True, **result} if isinstance(result, dict) else {"success": True, "report": result})
    except Exception as e:
        traceback.print_exc()
        return _error("ai_report_failed", str(e), "/powerbi/analyze-report")


@router.post("/clean")
def clean(payload: CleanRequest):
    try:
        sid, state = _session(payload.session_id)
        df = _working_df(payload, state)
        config = payload.config or {}
        cleaned, report = clean_dataframe(df, config)
        state["df"] = cleaned.copy()
        return to_json_safe({
            "success": True,
            "session_id": sid,
            "before": analyze_dataframe(df),
            "after": analyze_dataframe(cleaned),
            "cleaning_report": report,
            "export": _json_df(cleaned),
        })
    except Exception as e:
        traceback.print_exc()
        return _error("cleaning_failed", str(e), "/powerbi/clean")


@router.get("/transform/list")
def transform_list():
    from common.transformations.transformation_registry import all_transformations
    return to_json_safe({"success": True, "transformations": all_transformations()})


@router.post("/transform/preview")
def transform_preview(payload: PipelineRequest):
    sid, state = _session(payload.session_id)
    try:
        df = _working_df(payload, state)
        result = _ENGINE.preview(
            df,
            transformation_name=payload.transformation_name,
            query=payload.query,
            params=payload.params,
            sample_rows=payload.sample_rows,
        )
        if not result.success:
            return _error(_classify_transform_error(result.error), result.error or "Preview failed.", "/powerbi/transform/preview", session_id=sid)
        return to_json_safe({
            "success": True,
            "session_id": sid,
            "transformation": result.transformation,
            "preview": result.preview,
            "execution_time": result.execution_time,
        })
    except Exception as e:
        traceback.print_exc()
        return _error("transformation_failed", str(e), "/powerbi/transform/preview", session_id=sid)


@router.post("/transform/apply")
def transform_apply(payload: PipelineRequest):
    sid, state = _session(payload.session_id)
    try:
        df = _working_df(payload, state)
        result = _ENGINE.run(
            df,
            transformation_name=payload.transformation_name,
            query=payload.query,
            params=payload.params,
            history=state["history"],
            value_column=payload.value_column,
        )
        return _pipeline_result(result, state, sid)
    except Exception as e:
        traceback.print_exc()
        return _error("transformation_failed", str(e), "/powerbi/transform/apply", session_id=sid)


@router.post("/transform/undo")
def transform_undo(payload: DatasetPayload):
    if payload.session_id and payload.session_id not in _SESSIONS and not (payload.rows or payload.columns):
        return _error(
            "session_not_found",
            f"No session found for session_id '{payload.session_id}'. Call /powerbi/session first.",
            "/powerbi/transform/undo", session_id=payload.session_id,
        )
    sid, state = _session(payload.session_id)
    try:
        if state.get("df") is None:
            state["df"] = _working_df(payload, state)
        result = _ENGINE.undo(state["history"], value_column=None)
        return _pipeline_result(result, state, sid)
    except Exception as e:
        traceback.print_exc()
        return _error("transformation_failed", str(e), "/powerbi/transform/undo", session_id=sid)


@router.post("/transform/redo")
def transform_redo(payload: DatasetPayload):
    if payload.session_id and payload.session_id not in _SESSIONS and not (payload.rows or payload.columns):
        return _error(
            "session_not_found",
            f"No session found for session_id '{payload.session_id}'. Call /powerbi/session first.",
            "/powerbi/transform/redo", session_id=payload.session_id,
        )
    sid, state = _session(payload.session_id)
    try:
        if state.get("df") is None:
            state["df"] = _working_df(payload, state)
        result = _ENGINE.redo(state["history"], value_column=None)
        return _pipeline_result(result, state, sid)
    except Exception as e:
        traceback.print_exc()
        return _error("transformation_failed", str(e), "/powerbi/transform/redo", session_id=sid)


@router.get("/transform/history/{session_id}")
def transform_history(session_id: str):
    state = _SESSIONS.get(session_id)
    if state is None:
        return _error(
            "session_not_found", f"No session found for session_id '{session_id}'.",
            "/powerbi/transform/history",
        )
    return to_json_safe({"success": True, "history": state["history"].list()})


@router.post("/smart_query")
async def smart_query(payload: QueryRequest):
    """Reuses the exact same query_router.handle_smart_query() the Excel
    /smart_query route calls: rule-based transformation fast-path first,
    then DuckDB SQL / spreadsheet-action routing via the LLM router. Same
    engine, same behavior — only the DataFrame source differs."""
    sid, state = _session(payload.session_id)
    try:
        df = _working_df(payload, state)
        result = await handle_smart_query(payload.query, df, payload.available_sheets)
        if isinstance(result, dict):
            result.setdefault("success", True)
            result["session_id"] = sid
        return to_json_safe(result)
    except Exception as e:
        traceback.print_exc()
        return _error("smart_query_failed", str(e), "/powerbi/smart_query", session_id=sid)


@router.post("/agentic_command")
async def agentic_command(payload: AgenticCommandRequest):
    """Reuses command_agent.parse_agentic_command() exactly as the Excel
    /agentic_command route does. This route only needs column names (not
    row data), matching the underlying function's signature."""
    try:
        result = await parse_agentic_command(payload.text, payload.columns, payload.available_sheets)
        if isinstance(result, dict):
            result.setdefault("success", result.get("action") not in (None, "unknown"))
        return to_json_safe(result)
    except Exception as e:
        traceback.print_exc()
        return _error("agentic_command_failed", str(e), "/powerbi/agentic_command")
