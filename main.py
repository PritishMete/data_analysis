import re
import time
import logging
from typing import Any

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from dotenv import load_dotenv
import numpy as np
import pandas as pd
import io
import json
import traceback
from command_agent import parse_agentic_command
from query_router import handle_smart_query
from data_cleaner import clean_dataframe
from common.excel_context import ExcelContextError, scan_workbook
from common.transformations import TransformationEngine, TransformationHistory, transformation_names

logger = logging.getLogger(__name__)


from common.json_safe import to_json_safe


def json_safe(obj: Any) -> Any:
    """Backwards-compatible alias — this file used to carry its own
    standalone implementation of this logic, duplicated from (and slightly
    out of sync with) query_router.py, which had none at all (its
    `_operation_error_response()` and several `handle_smart_query()`
    branches returned raw dicts that were only made JSON-safe if/when this
    file happened to wrap them). Both now share ONE implementation,
    `common.json_safe.to_json_safe`, so a fix in one place fixes every
    route. Kept as a thin wrapper — rather than renaming every call site in
    this file — to minimize diff / risk.
    """
    return to_json_safe(obj)


from common.response_envelope import smart_query_envelope


def smart_query_error_response(
    message: str,
    *,
    error_type: str = "INTERNAL_ERROR",
    confidence: float = 0.0,
    extra_operation_fields: dict | None = None,
) -> dict:
    """Builds an error response in the SAME envelope shape every successful
    /smart_query response already uses (success/route/operation/metadata/
    preview/statistics/schema/ai_report/warnings/errors) — see TASK 7 /
    common/response_envelope.py — so Flutter's dispatch logic never has to
    special-case "this was an error" vs "this was operation route X"; it's
    always the same top-level shape with the same keys present.
    """
    operation = {"action": "transformation_error", "error_type": error_type, "error": message}
    if extra_operation_fields:
        operation.update(extra_operation_fields)
    return smart_query_envelope(
        success=False,
        route="operation",
        message=message,
        confidence=confidence,
        operation=operation,
        errors=[{"error_type": error_type, "message": message}],
    )

# ── Enterprise Analytics Platform extensions (new, additive) ────────────────
# Everything above this line is completely untouched. These imports bring in
# the Dataset Registry / Schema Intelligence / Query History / Plan Cache
# packages so /agentic_command below can optionally use them — see the
# dataset_id-gated block inside that route for exactly what changed and why
# it's backward compatible with every existing caller.
from core.db import SessionLocal, init_db
from datasets.repository import DatasetRepository
from datasets.routes import dataset_registry_router
from schema_intelligence.routes import schema_intelligence_router
from query_history.repository import QueryHistoryRepository
from query_history.routes import query_history_router
from query_history.service import QueryHistoryService
from ingestion.routes import ingestion_router
from plan_cache.repository import PlanCacheRepository
from plan_cache.routes import plan_cache_router
from plan_cache.service import PlanCacheService
from sql_cache.middleware import SqlCacheMiddleware
from sql_cache.routes import sql_cache_router
from memory_engine.routes import memory_engine_router

# Load environment variables from .env (GOOGLE_API_KEY, etc.)
# On Render, these are set directly in the dashboard instead, but load_dotenv()
# is harmless there too — it just won't find a .env file and does nothing.
load_dotenv()

from ai_analyst import (
    generate_report,
    generate_structured_report,
    suggest_analysis_types,
    explain_business_problems,
)

app = FastAPI()

# Allow Flutter/Web requests AND the Power BI Custom Visual sandbox.
# NOTE (security fix): `allow_origins=["*"]` combined with
# `allow_credentials=True` is a known-bad CORS combination — browsers
# reject credentialed wildcard requests outright, and where a proxy doesn't
# enforce that, it needlessly widens the attack surface for no benefit here:
# nothing in this API uses cookies (session_id is passed as an explicit
# JSON/Form field, never a cookie — verified: no Set-Cookie/cookie usage
# anywhere in this codebase). `allow_credentials` is set to False rather
# than pinning `allow_origins` to a fixed list, because a fixed list isn't
# viable for the Power BI visual specifically: Power BI Desktop's report
# webview sends requests from a sandboxed/"null" origin, and Power BI
# Service origins vary by tenant/region (app.powerbi.com and several
# regional/embed/msit variants) — none of which can be enumerated up
# front. Wildcard + no-credentials is the correct, deliberate choice here,
# not a placeholder. `allow_methods=["*"]` covers OPTIONS too: Starlette's
# CORSMiddleware answers CORS preflight (OPTIONS) requests itself before
# routing, for any path, independent of which methods a given route
# registers — verified below with a direct OPTIONS request against
# /powerbi/transform/apply.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Centralized Transformation Engine (new, additive) ────────────────────
# Single engine instance — it's stateless (holds no dataframe/session data
# itself; see common/transformations/transformation_engine.py). Every
# transformation route below (range binning, rename, drop, fill missing,
# dedupe, merge/split columns, type conversion, date features, and any
# future transformation registered in common/transformations/adapters/)
# goes through this ONE engine — no per-transformation duplicate pipeline.
#
# `_TRANSFORMATION_HISTORIES` is a process-local, in-memory map of
# session_id -> TransformationHistory, powering Undo/Redo/Replay across
# requests. This mirrors this backend's existing stateless-upload pattern
# (no route persists an in-progress dataframe server-side today) rather
# than introducing a new database-backed session layer; a client that wants
# history simply passes the same `session_id` on each /transform/* call.
#
# MEMORY FIX: each TransformationHistoryEntry keeps full before/after
# DataFrame snapshots (see transformation_history.py) — without eviction,
# every session that ever calls /transform/apply lives in this dict forever
# and never frees that memory, which is an unbounded-growth/OOM risk in
# production. `_TRANSFORMATION_HISTORY_LAST_ACCESS` tracks per-session idle
# time, and `_evict_stale_histories()` (called on every history lookup, so
# no background thread/extra concurrency primitive is needed) drops any
# session that's been idle past `_SESSION_TTL_SECONDS`. This does NOT
# truncate an active session's entries — undo/redo/replay correctness for
# any session still in use is completely unaffected; only whole sessions
# that have gone idle are freed.
#
# This is a same-process stopgap, not a full fix: it still doesn't survive
# multiple worker processes/replicas (a session's history only exists on
# whichever process created it) or a process restart. The real fix for a
# horizontally-scaled deployment is to move this to a shared store with
# native TTL (e.g. Redis) — flagged here rather than silently left as-is.
_transformation_engine = TransformationEngine()
_TRANSFORMATION_HISTORIES: dict[str, TransformationHistory] = {}
_TRANSFORMATION_HISTORY_LAST_ACCESS: dict[str, float] = {}
_SESSION_TTL_SECONDS = 2 * 60 * 60  # 2 hours idle


def _evict_stale_histories() -> None:
    now = time.monotonic()
    stale = [
        sid for sid, last_seen in _TRANSFORMATION_HISTORY_LAST_ACCESS.items()
        if now - last_seen > _SESSION_TTL_SECONDS
    ]
    for sid in stale:
        _TRANSFORMATION_HISTORIES.pop(sid, None)
        _TRANSFORMATION_HISTORY_LAST_ACCESS.pop(sid, None)


def _get_or_create_history(session_id: str | None) -> TransformationHistory | None:
    if not session_id:
        return None
    _evict_stale_histories()
    _TRANSFORMATION_HISTORY_LAST_ACCESS[session_id] = time.monotonic()
    if session_id not in _TRANSFORMATION_HISTORIES:
        _TRANSFORMATION_HISTORIES[session_id] = TransformationHistory()
    return _TRANSFORMATION_HISTORIES[session_id]

# ── SQL Cache (new, additive) ────────────────────────────────────────────
# Sits in front of /agentic_command (JSON) AND /smart_query (multipart file
# upload — the query text is extracted from raw bytes without ever calling
# Starlette's request.form(), which was verified to break downstream
# File()/Form() parsing if called here; see sql_cache/multipart_utils.py).
# On a >=95%-similar match against a past SUCCESSFUL query (see
# sql_cache/service.py), returns the cached result directly and the route
# below — and whatever Gemini call it would have made — never runs at all.
# A miss is a complete no-op; the route runs exactly as it does today,
# including on /smart_query where the uploaded file's bytes are proven to
# reach the route completely unmodified. Zero changes to command_agent.py's
# or query_router.py's planner logic, and zero changes to either route's
# own code. Modular/replaceable: swap the similarity_strategy, threshold, or
# watched_paths here without touching sql_cache/middleware.py itself.
app.add_middleware(
    SqlCacheMiddleware,
    watched_paths=("/agentic_command", "/smart_query"),
    min_confidence=0.95,
)

# ---------------------------------------------------------
# Blank / invisible-character normalization
# ---------------------------------------------------------
# Matches a string that is EMPTY or made up ENTIRELY of characters that look
# blank in Excel but aren't a plain "" — regular whitespace, non-breaking
# space, zero-width space/non-joiner/joiner, BOM, soft hyphen, word joiner.
# Without this, a cell like that survives client-side CSV building as a
# non-empty (but invisible) string, so pandas' isnull() never flags it as
# missing, and nunique() silently counts it as an extra "unique" value.
_BLANK_LIKE_RE = re.compile(
    r"^[\s\u00A0\u200B\u200C\u200D\uFEFF\u00AD\u2060]*$"
)


def _normalize_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """
    Guarantees that "blank-looking" cells are actually treated as missing
    (NaN), no matter whether they arrived as a real empty string, a
    whitespace-only string, or a string made up of invisible Unicode
    characters (non-breaking space, zero-width space, BOM, etc.).

    This is applied once, right after any file is loaded, so every route
    downstream (/analyze, /analyze-report, /smart_query, ...) sees the same
    correctly-nulled data — regardless of what the client sent.
    """
    df = df.copy()
    for col in df.select_dtypes(include=["object"]).columns:
        # Strip genuine leading/trailing whitespace on real strings first.
        df[col] = df[col].apply(lambda v: v.strip() if isinstance(v, str) else v)
        # Anything that is empty, or entirely made of invisible/blank
        # characters, becomes a true NaN instead of a "valid" string.
        df[col] = df[col].apply(
            lambda v: np.nan if isinstance(v, str) and _BLANK_LIKE_RE.match(v) else v
        )
    return df


# ---------------------------------------------------------
# Dataset profiling -- moved to common/analytics/profiling.py so both
# this file and powerbi_routes.py import it from ONE shared place
# instead of powerbi_routes.py importing it from here (which used to
# create a main.py <-> powerbi_routes.py circular dependency).
# ---------------------------------------------------------
from common.analytics.profiling import analyze_dataframe


def _load_dataframe(filename: str, contents: bytes) -> pd.DataFrame:
    """Shared file-parsing logic used by /analyze, /analyze-report,
    /suggest_analysis_types, /analyze-report-focused, and /smart_query.

    Every caller now goes through this single function, and every caller
    gets the same _normalize_dataframe() pass applied — so blank/invisible-
    character cells are guaranteed to show up as real NaNs everywhere,
    instead of only in whichever route happened to have its own fillna
    guard.
    """
    filename = filename.lower()
    if filename.endswith(".csv"):
        # Not every CSV in the wild is valid UTF-8 (e.g. Latin-1/cp1252
        # exports with accented characters). Try utf-8 first, then fall
        # back through the common alternatives instead of hard-failing.
        last_err = None
        df = None
        for encoding in ("utf-8", "latin1", "cp1252"):
            try:
                df = pd.read_csv(io.BytesIO(contents), encoding=encoding)
                break
            except UnicodeDecodeError as e:
                last_err = e
        if df is None:
            raise ValueError(f"Could not decode CSV with utf-8/latin1/cp1252: {last_err}")
    elif filename.endswith(".xlsx"):
        df = pd.read_excel(io.BytesIO(contents))
    elif filename.endswith(".json"):
        data = json.loads(contents.decode("utf-8"))
        df = pd.DataFrame(data)
    else:
        raise ValueError("Unsupported file format")

    return _normalize_dataframe(df)


# ---------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------
class BusinessProblemsRequest(BaseModel):
    profile: dict
    selected_ids: list[str]
    analysis_titles: dict[str, str] = {}


class FocusedReportRequest(BaseModel):
    # focus_analysis_types is optional — when omitted, /analyze-report-focused
    # behaves like the original /analyze-report (fully generic report).
    focus_analysis_types: list[dict] = []


class CleaningConfigRequest(BaseModel):
    """Configuration for data cleaning operations."""
    standardize_cols: bool = True
    remove_duplicates: bool = True
    remove_empty_rows: bool = True
    handle_missing_values: bool = True
    null_strategy: str = "smart"  # 'smart', 'mean', 'median', 'mode', 'forward_fill', 'drop'
    normalize_text: bool = True
    infer_types: bool = True
    handle_outliers: bool = False
    outlier_method: str = "cap"  # 'cap', 'remove', 'mark'
    output_sheet_name: str = "Cleaned_Data"


# ---------------------------------------------------------
# Context-aware loader
# ---------------------------------------------------------
def _load_context_aware_dataframe(
    filename: str | None,
    contents: bytes,
    sheet_name: str | None = None,
    active_cell: str | None = None,
    dataset_range: str | None = None,
):
    """Load the exact Excel dataset selected by the client when context exists.

    With no Excel context this intentionally falls back to the legacy loader,
    preserving CSV/XLSX behavior for existing clients.
    """
    if filename and filename.lower().endswith((".xlsx", ".xlsm")) and (
        sheet_name or active_cell or dataset_range
    ):
        df, context = scan_workbook(
            contents,
            filename,
            sheet_name=sheet_name,
            active_cell=active_cell,
            requested_range=dataset_range,
        )
        return _normalize_dataframe(df), context
    return _load_dataframe(filename, contents), None


# ---------------------------------------------------------
# API Route — raw stats (existing)
# ---------------------------------------------------------
@app.post("/analyze")
async def analyze(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    contents = await file.read()
    try:
        # NOTE: now goes through the shared _load_dataframe() helper (same
        # one /analyze-report and /smart_query use), instead of duplicating
        # the csv/xlsx/json parsing inline. This guarantees /analyze sees
        # the exact same _normalize_dataframe() treatment as every other
        # route, so missing_values/unique_values reflect the TRUE raw data
        # — blank-looking cells (real empty, whitespace-only, or invisible
        # Unicode characters) are always counted as missing, never silently
        # kept as a "valid" distinct value.
        df, context = _load_context_aware_dataframe(
            file.filename, contents, sheet_name, active_cell, dataset_range
        )
        result = analyze_dataframe(df)
        if context:
            result["excel_context"] = context
        # TEMP DIAGNOSTIC — remove once you've confirmed the deployed
        # backend is actually running this updated file. If this key is
        # missing from the response your app receives, Render is still
        # serving an OLDER build and the fix below hasn't gone live yet.
        result["_normalization_fix_active"] = True
        return result
    except ValueError as e:
        return {"error": str(e)}
    except Exception as e:
        return {"error": str(e)}


# ---------------------------------------------------------
# API Route — AI-narrated report (existing, unchanged behavior)
# ---------------------------------------------------------
@app.post("/analyze-report")
async def analyze_report(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    contents = await file.read()
    try:
        df, context = _load_context_aware_dataframe(
            file.filename, contents, sheet_name, active_cell, dataset_range
        )
        result = await generate_report(df)
        if context and isinstance(result, dict):
            result["excel_context"] = context
        return result
    except ValueError as e:
        return {"error": str(e)}
    except Exception as e:
        return {"error": str(e)}


# ---------------------------------------------------------
# API Route — Data Cleaning with Detailed Report
# ---------------------------------------------------------
@app.post("/clean_data")
async def clean_data(
    file: UploadFile = File(...),
    config: str = Form("{}"),
):
    """
    Advanced data cleaning with intelligent strategies for different data types.
    
    Accepts cleaning configuration and returns:
    1. Before/after analysis comparison
    2. Detailed cleaning report (operations, affected columns, changes)
    3. Cleaned dataframe preview
    4. Recommendations for writing to new sheet (Excel interop compatible)
    
    config: JSON string with CleaningConfigRequest fields
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e), "success": False}
    
    # Parse configuration
    try:
        config_dict = json.loads(config) if config and config != "{}" else {}
    except json.JSONDecodeError:
        config_dict = {}
    
    # Validate and set defaults
    cleaning_config = {
        "standardize_cols": config_dict.get("standardize_cols", True),
        "remove_duplicates": config_dict.get("remove_duplicates", True),
        "remove_empty_rows": config_dict.get("remove_empty_rows", True),
        "handle_missing_values": config_dict.get("handle_missing_values", True),
        "null_strategy": config_dict.get("null_strategy", "smart"),
        "normalize_text": config_dict.get("normalize_text", True),
        "infer_types": config_dict.get("infer_types", True),
        "handle_outliers": config_dict.get("handle_outliers", False),
        "outlier_method": config_dict.get("outlier_method", "cap"),
        "steps": config_dict.get("steps"),  # optional ordered list — overrides fixed pipeline order
    }
    
    output_sheet_name = config_dict.get("output_sheet_name", "Cleaned_Data")
    
    try:
        # Analyze BEFORE cleaning
        before_analysis = analyze_dataframe(df)
        
        # Run cleaning
        cleaned_df, cleaning_report = clean_dataframe(df, cleaning_config)
        
        # Analyze AFTER cleaning
        after_analysis = analyze_dataframe(cleaned_df)
        
        # Build comparison
        comparison = {
            "rows_removed": before_analysis["summary"]["rows"] - after_analysis["summary"]["rows"],
            "columns_removed": before_analysis["summary"]["columns"] - after_analysis["summary"]["columns"],
            "total_missing_before": sum(before_analysis["missing_values"].values()),
            "total_missing_after": sum(after_analysis["missing_values"].values()),
            "total_duplicates_before": before_analysis["duplicates"]["count"],
            "total_duplicates_after": after_analysis["duplicates"]["count"],
        }
        
        # Prepare cleaned data export format (for Excel sheet writing)
        export_data = {
            "sheet_name": output_sheet_name,
            "columns": list(cleaned_df.columns),
            "rows": cleaned_df.fillna("").to_dict(orient="records"),
            "row_count": len(cleaned_df),
        }
        
        return {
            "success": True,
            "before": before_analysis,
            "after": after_analysis,
            "comparison": comparison,
            "cleaning_report": cleaning_report,
            "export": export_data,
            "summary": f"✅ Cleaned data: {after_analysis['summary']['rows']} rows × {after_analysis['summary']['columns']} columns. "
                      f"Removed {comparison['rows_removed']} duplicate/empty rows, "
                      f"filled {cleaning_report['cells_filled']} missing values.",
        }
    
    except Exception as e:
        print("[/clean_data] EXCEPTION:")
        traceback.print_exc()
        return {
            "success": False,
            "error": str(e),
            "message": f"Cleaning failed: {str(e)}",
        }


# ---------------------------------------------------------
# API Route — Column Binning / Range Categorization
# ---------------------------------------------------------
@app.post("/transform/range_binning")
async def range_binning_endpoint(
    file: UploadFile = File(...),
    text: str | None = Form(None),
    source_column: str | None = Form(None),
    ranges: str | None = Form(None),          # JSON-encoded list[str], optional
    new_column: str | None = Form(None),
    session_id: str | None = Form(None),      # optional — enables undo/redo/history
):
    """
    Creates a new categorical column from a numeric column by bucketing its
    values into ranges — e.g. "Rating" -> "Rating_Range" with values like
    "0-1", "1-2", etc.

    Two ways to call this:
      - text: a natural-language request, e.g. "Create column for rating
        range 0-1,1-2,2-3,3-4,4-5" or "Create salary bands" — source_column
        and ranges are auto-detected via the range_binning transformation's
        own detect().
      - source_column (+ optional ranges, new_column): explicit parameters,
        e.g. when the Flutter UI already collected them from the user.

    Internally this now delegates to the SAME centralized TransformationEngine
    every other /transform/* route uses (see common/transformations/) — this
    endpoint's request/response SHAPE is unchanged from before for backward
    compatibility, but there is no longer a range-binning-specific pipeline
    running underneath it; `/transform/apply` below hits the identical code
    path for every transformation, including this one.
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e), "success": False}

    try:
        ranges_list = json.loads(ranges) if ranges else None
    except json.JSONDecodeError:
        return {"success": False, "error": "`ranges` must be a JSON-encoded list of strings."}

    before_analysis = analyze_dataframe(df)
    history = _get_or_create_history(session_id)

    if source_column:
        result = _transformation_engine.run(
            df, transformation_name="range_binning",
            params={"source_column": source_column, "ranges": ranges_list, "new_column": new_column},
            history=history,
        )
    else:
        result = _transformation_engine.run(df, query=text, history=history)

    if not result.success:
        return {"success": False, "error": result.error, "message": result.error}

    new_df = result.dataframe
    metadata = result.metadata
    after_analysis = analyze_dataframe(new_df)
    ai_report = result.updated_ai_report

    export_data = {
        "sheet_name": "range_binning_output",
        "columns": list(new_df.columns),
        "rows": new_df.fillna("").to_dict(orient="records"),
        "row_count": len(new_df),
    }

    return {
        "success": True,
        "metadata": metadata,
        "transformation": {
            "applied": True,
            "type": "range_binning",
            "source_column": metadata["source_column"],
            "new_column": metadata["new_column"],
            "range_count": len(metadata["ranges"]),
            "categories_created": metadata["ranges"],
            "history_id": result.transformation.get("history_id"),
        },
        "preview": result.preview,
        "explanation": metadata.get("explanation"),
        "message": result.message,
        "schema": after_analysis["summary"],
        "statistics": {
            "before": before_analysis,
            "after": after_analysis,
        },
        "ai_report": ai_report,
        "chart_recommendation": ai_report.get("chart_recommendation"),
        "export": export_data,
    }


# ---------------------------------------------------------
# API Routes — Centralized Transformation Engine (generic, ALL transformations)
# ---------------------------------------------------------
# These four routes are the single generic entry point for every
# transformation registered in common/transformations/adapters/ — range
# binning, rename, drop, fill missing, dedupe, merge/split columns, type
# conversion, date features, and any transformation added in the future.
# /transform/range_binning above is kept only for existing callers; it now
# runs through this exact same engine underneath.
@app.get("/transform/list")
async def list_transformations():
    """Lets the Flutter 'Transformation Center' build its UI from whatever
    is actually registered, instead of a hardcoded list."""
    return {
        "success": True,
        "transformations": [
            {"name": name, "display_name": _transformation_engine.registry_get(name).display_name}
            for name in transformation_names()
        ],
    }


@app.post("/transform/preview")
async def transform_preview(
    file: UploadFile = File(...),
    transformation_name: str | None = Form(None),
    text: str | None = Form(None),
    params: str | None = Form(None),  # JSON-encoded dict, optional
):
    """Preview-only: never mutates the dataframe, never touches history."""
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e), "success": False}

    try:
        params_dict = json.loads(params) if params else None
    except json.JSONDecodeError:
        return {"success": False, "error": "`params` must be a JSON-encoded object."}

    result = _transformation_engine.preview(
        df, transformation_name=transformation_name, query=text, params=params_dict,
    )
    return {
        "success": result.success,
        "transformation": result.transformation,
        "preview": result.preview,
        "error": result.error,
        "execution_time": result.execution_time,
    }


@app.post("/transform/apply")
async def transform_apply(
    file: UploadFile = File(...),
    transformation_name: str | None = Form(None),
    text: str | None = Form(None),
    params: str | None = Form(None),          # JSON-encoded dict, optional
    value_column: str | None = Form(None),
    session_id: str | None = Form(None),      # enables undo/redo/history
):
    """Generic apply for ANY registered transformation — the same engine
    call /transform/range_binning now delegates to internally. Refreshes
    schema, statistics, KPIs, trend, outliers, recommendations, chart
    recommendation, and the executive summary in the SAME response, via
    the existing common/report/orchestrator.py — no second dataset scan.
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e), "success": False}

    try:
        params_dict = json.loads(params) if params else None
    except json.JSONDecodeError:
        return {"success": False, "error": "`params` must be a JSON-encoded object."}

    history = _get_or_create_history(session_id)
    result = _transformation_engine.run(
        df, transformation_name=transformation_name, query=text,
        params=params_dict, history=history, value_column=value_column,
    )

    if not result.success:
        return {"success": False, "error": result.error, "message": result.error}

    new_df = result.dataframe
    return {
        "success": True,
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
        "history": history.list() if history else [],
        "export": {
            "columns": list(new_df.columns),
            "rows": new_df.fillna("").to_dict(orient="records"),
            "row_count": len(new_df),
        },
    }


@app.post("/transform/undo")
async def transform_undo(session_id: str = Form(...), value_column: str | None = Form(None)):
    history = _TRANSFORMATION_HISTORIES.get(session_id)
    if history is None:
        return {"success": False, "error": f"No transformation history found for session_id '{session_id}'."}
    result = _transformation_engine.undo(history, value_column=value_column)
    if not result.success:
        return {"success": False, "error": result.error}
    new_df = result.dataframe
    return {
        "success": True,
        "transformation": result.transformation,
        "updated_schema": result.updated_schema,
        "updated_statistics": result.updated_statistics,
        "updated_kpis": result.updated_kpis,
        "updated_charts": result.updated_charts,
        "updated_ai_report": result.updated_ai_report,
        "message": result.message,
        "history": history.list(),
        "export": {
            "columns": list(new_df.columns),
            "rows": new_df.fillna("").to_dict(orient="records"),
            "row_count": len(new_df),
        },
    }


@app.post("/transform/redo")
async def transform_redo(session_id: str = Form(...), value_column: str | None = Form(None)):
    history = _TRANSFORMATION_HISTORIES.get(session_id)
    if history is None:
        return {"success": False, "error": f"No transformation history found for session_id '{session_id}'."}
    result = _transformation_engine.redo(history, value_column=value_column)
    if not result.success:
        return {"success": False, "error": result.error}
    new_df = result.dataframe
    return {
        "success": True,
        "transformation": result.transformation,
        "updated_schema": result.updated_schema,
        "updated_statistics": result.updated_statistics,
        "updated_kpis": result.updated_kpis,
        "updated_charts": result.updated_charts,
        "updated_ai_report": result.updated_ai_report,
        "message": result.message,
        "history": history.list(),
        "export": {
            "columns": list(new_df.columns),
            "rows": new_df.fillna("").to_dict(orient="records"),
            "row_count": len(new_df),
        },
    }


@app.get("/transform/history/{session_id}")
async def transform_history(session_id: str):
    history = _TRANSFORMATION_HISTORIES.get(session_id)
    if history is None:
        return {"success": True, "history": []}
    return {"success": True, "history": history.list()}


# ---------------------------------------------------------
# API Route — suggest which analysis types this dataset supports
# ---------------------------------------------------------
@app.post("/suggest_analysis_types")
async def suggest_analysis_types_endpoint(file: UploadFile = File(...)):
    """
    Step 1 of the new report flow: given the uploaded dataset, returns a
    short list of analysis types (e.g. Pricing Analysis, Revenue Analysis,
    Growth Analysis) that are genuinely supported by the columns actually
    present — plus a "profile" object the client should hang onto and pass
    straight into /analysis_business_context, so that step doesn't need a
    second file upload.
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
        result = await suggest_analysis_types(df)
        return result
    except ValueError as e:
        return {"error": str(e)}
    except Exception as e:
        print("[/suggest_analysis_types] EXCEPTION:")
        traceback.print_exc()
        return {"error": str(e)}


# ---------------------------------------------------------
# API Route — business problems addressed by the selected analysis type(s)
# ---------------------------------------------------------
@app.post("/analysis_business_context")
async def analysis_business_context_endpoint(req: BusinessProblemsRequest):
    """
    Step 2 of the new report flow: given the profile returned by
    /suggest_analysis_types and the id(s) the user selected, returns 2-4
    concrete business problems each selected analysis type could help
    address for this specific dataset.
    """
    try:
        result = await explain_business_problems(req.profile, req.selected_ids, req.analysis_titles)
        return result
    except Exception as e:
        print("[/analysis_business_context] EXCEPTION:")
        traceback.print_exc()
        return {"error": str(e)}


# ---------------------------------------------------------
# API Route — AI-narrated report, focused on selected analysis type(s)
# ---------------------------------------------------------
@app.post("/analyze-report-focused")
async def analyze_report_focused(
    file: UploadFile = File(...),
    focus_analysis_types: str = Form("[]"),
    value_column: str = Form(None),
    period_column: str = Form(None),
    question: str = Form(None),
):
    """
    Same as /analyze-report, but accepts the analysis type(s) the user
    selected (JSON-encoded list of {"id","title"} dicts).

    The selected ids drive which STRUCTURED analytics
    (statistics/trend_insight/outliers/detected_kpis/recommendations/
    chart_recommendation/data_quality/executive_summary) are actually
    computed — by the existing Python detectors in common/insights and
    common/statistics, never by Gemini — and returned in a shape compatible
    with the Flutter AiReport.fromJson() model. Gemini remains responsible
    only for the human-readable 'report' narrative, and is given those
    structured results as context rather than calculating anything itself.

    value_column/period_column are optional; when omitted a reasonable
    default is auto-detected from the dataset. `question` is optional
    free-text that sharpens the chart recommendation.
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e)}

    try:
        focus_list = json.loads(focus_analysis_types)
    except json.JSONDecodeError:
        focus_list = []

    selected_analysis_ids = [
        item.get("id") for item in focus_list
        if isinstance(item, dict) and item.get("id")
    ]

    try:
        result = await generate_structured_report(
            df,
            selected_analysis_ids=selected_analysis_ids,
            focus_analysis_types=focus_list or None,
            value_column=value_column or None,
            period_column=period_column or None,
            question=question or None,
        )
        return result
    except Exception as e:
        print("[/analyze-report-focused] EXCEPTION:")
        traceback.print_exc()
        return {"error": str(e)}


# ---------------------------------------------------------
# agentic operation
# ---------------------------------------------------------

@app.post("/agentic_command")
async def agentic_command(payload: dict):
    text = payload.get("text", "")
    available_columns = payload.get("available_columns", [])
    available_sheets = payload.get("available_sheets", [])

    # ── Enterprise extension: OPTIONAL, backward-compatible fields ─────────
    # Existing callers (today's agentic_command_executor.dart) never send
    # these, so `dataset_id` is None for them and every block below is
    # skipped entirely — behavior is byte-identical to before this change.
    # Once the Flutter side is ready to opt in, sending `dataset_id` (and
    # optionally `organization_id`) unlocks:
    #   1. A plan-cache check BEFORE calling Gemini at all, and
    #   2. Logging of what got parsed, for that cache to learn from.
    # NOTE (honest limitation): "success" logged here reflects PARSE-time
    # confidence (did command_agent.py produce a usable action?), not
    # confirmed execution outcome — the actual Excel operation runs in
    # Flutter, and reporting whether IT succeeded back to /v2/query-history
    # (already built, see query_history/routes.py) needs a Flutter-side call
    # this project's rules say not to add here. That's the one remaining
    # wire-up, and it's a one-line addition on the Flutter side whenever
    # that's wanted — not a backend gap.
    dataset_id = payload.get("dataset_id")
    organization_id = payload.get("organization_id")

    if dataset_id:
        try:
            db = SessionLocal()
            try:
                plan_cache_service = PlanCacheService(DatasetRepository(db), PlanCacheRepository(db))
                cached = plan_cache_service.find_cached_plan(dataset_id=dataset_id, user_query=text)
                if cached is not None and isinstance(cached.python_pipeline, dict):
                    cached_result = dict(cached.python_pipeline)
                    cached_result["message"] = (
                        cached_result.get("message", "")
                        + " (reused from a previous execution — no AI call made)"
                    ).strip()
                    cached_result["_plan_cache_hit"] = True
                    cached_result["_matched_on"] = cached.matched_on
                    return cached_result
            finally:
                db.close()
        except Exception:
            # Cache lookup is a pure optimization — never let a problem here
            # block the actual request; fall through to the normal path.
            print("[/agentic_command] plan cache lookup failed:")
            traceback.print_exc()

    try:
        result = await parse_agentic_command(text, available_columns, available_sheets)

        if dataset_id:
            try:
                db = SessionLocal()
                try:
                    QueryHistoryService(QueryHistoryRepository(db), DatasetRepository(db)).log_execution(
                        user_query=text,
                        intent=result.get("action"),
                        python_pipeline=result,
                        dataset_id=dataset_id,
                        organization_id=organization_id,
                        success=result.get("action") not in (None, "unknown"),
                    )
                finally:
                    db.close()
            except Exception:
                # Same principle as above — logging must never break the
                # actual response the user is waiting on.
                print("[/agentic_command] query history logging failed:")
                traceback.print_exc()

        return result
    except Exception as e:
        # Print full traceback to Render logs — the previous version only
        # returned the error message to the client, so the real cause never
        # showed up anywhere visible.
        print("[/agentic_command] EXCEPTION:")
        traceback.print_exc()
        return {"action": "unknown", "confidence": 0.0, "message": f"Error: {str(e)}"}


# ---------------------------------------------------------
# Smart query — AI decides SQL vs. traditional spreadsheet operation
# ---------------------------------------------------------

@app.post("/smart_query")
async def smart_query(
    file: UploadFile = File(...),
    text: str = Form(...),
    available_sheets: str = Form("[]"),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    """
    Single entry point for natural-language requests. The router agent decides
    whether this is:
      - an analytical QUESTION -> generates + runs a read-only SQL SELECT via
        DuckDB against the uploaded data, returning rows directly, or
      - a spreadsheet ACTION (pivot/filter/deduplicate/color_scale) -> falls
        through to the existing agentic_command parser, returning the same
        structured JSON /agentic_command would, for the Flutter app to execute.

    available_sheets is a JSON-encoded list string (e.g. '["Sheet1","Orders"]'),
    passed the same way the existing /agentic_command route expects it.
    For Excel workbooks, sheet_name/active_cell/dataset_range are optional context
    supplied by the Excel client. When present, the query is executed against the
    selected dataset instead of blindly reading the workbook's first sheet.
    """
    # HARDENING (production-grade error handling):
    # Everything below — file parsing, dataframe loading, the actual
    # handle_smart_query() call, AND building/serializing the response — now
    # happens inside ONE try/except. This matters specifically because of
    # where exceptions ended up: the previous version's try/except only
    # covered handle_smart_query() itself, so (a) the dataframe-load step
    # above used a narrower except that could miss exception types other
    # than ValueError/ExcelContextError, and (b) more importantly, nothing
    # guarded response *serialization* — a raw numpy/pandas value anywhere
    # in the result dict (a KPI computed via .sum()/.nunique(), a dtype
    # object in a schema diff, a Timestamp in a preview row) would only
    # fail when Starlette tried to JSON-encode the return value, which
    # happens AFTER this function has already returned — outside the reach
    # of any try/except inside it. Building the JSONResponse explicitly,
    # inside this try block, with json_safe() run over the content first,
    # means that failure mode is now caught here instead of surfacing as an
    # unexplained dropped connection.
    try:
        contents = await file.read()
        try:
            df, excel_context = _load_context_aware_dataframe(
                file.filename, contents, sheet_name, active_cell, dataset_range
            )
        except (ValueError, ExcelContextError) as e:
            return JSONResponse(status_code=200, content=json_safe(
                smart_query_error_response(str(e), error_type="DATA_LOAD_FAILED")
            ))

        try:
            sheets = json.loads(available_sheets)
        except json.JSONDecodeError:
            sheets = []

        result = await handle_smart_query(text, df, sheets)
        if excel_context and isinstance(result, dict):
            result["excel_context"] = excel_context

        safe_result = json_safe(result)
        # Belt-and-suspenders: prove it actually serializes with the exact
        # same encoder FastAPI/Starlette would use, INSIDE this try block,
        # rather than trusting json_safe() unconditionally.
        json.dumps(safe_result, allow_nan=False)
        return JSONResponse(status_code=200, content=safe_result)

    except Exception as e:
        logger.exception("[/smart_query] Unhandled exception")
        try:
            fallback = json_safe(smart_query_error_response(
                "Transformation failed.", error_type="TRANSFORMATION_ENGINE_EXCEPTION",
                extra_operation_fields={"exception": str(e)},
            ))
            json.dumps(fallback, allow_nan=False)  # final safety check before we trust this is returnable
        except Exception:
            # json_safe() is designed to never raise and always produce
            # something json.dumps can handle, but if str(e) itself somehow
            # can't round-trip, fall back to the smallest possible valid
            # response rather than let THIS raise too.
            fallback = {
                "route": "operation",
                "success": False,
                "confidence": 0.0,
                "message": "Transformation failed.",
                "operation": {"action": "transformation_error", "error_type": "TRANSFORMATION_ENGINE_EXCEPTION"},
            }
        return JSONResponse(status_code=200, content=fallback)


# ---------------------------------------------------------
# Excel context-aware workbook scanning
# ---------------------------------------------------------
@app.post("/v2/excel/scan")
async def scan_excel_context(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
    dataset_range: str | None = Form(None),
):
    """Resolve the Excel context before analysis.

    The Excel client should send the active worksheet and active cell. The
    backend then deterministically finds the surrounding dataset (or honours
    an explicit dataset range), returns the sheet/range metadata, and exposes
    the scanned rows for downstream analysis.
    """
    raw = await file.read()
    try:
        df, context = scan_workbook(
            raw,
            file.filename or "workbook.xlsx",
            sheet_name=sheet_name,
            active_cell=active_cell,
            requested_range=dataset_range,
        )
        return {
            "success": True,
            "context": context,
            "data": df.where(pd.notna(df), None).to_dict(orient="records"),
        }
    except ExcelContextError as exc:
        return {"success": False, "error": str(exc)}
    except Exception as exc:
        print("[/v2/excel/scan] EXCEPTION:")
        traceback.print_exc()
        return {"success": False, "error": f"Excel scan failed: {exc}"}


@app.post("/v2/excel/context")
async def excel_context(
    file: UploadFile = File(...),
    sheet_name: str | None = Form(None),
    active_cell: str | None = Form(None),
):
    """Return workbook sheet names and active-selection dataset metadata."""
    raw = await file.read()
    try:
        _, context = scan_workbook(
            raw,
            file.filename or "workbook.xlsx",
            sheet_name=sheet_name,
            active_cell=active_cell,
        )
        return {"success": True, "context": context}
    except ExcelContextError as exc:
        return {"success": False, "error": str(exc)}
    except Exception as exc:
        print("[/v2/excel/context] EXCEPTION:")
        traceback.print_exc()
        return {"success": False, "error": f"Excel context failed: {exc}"}

# ---------------------------------------------------------
# Root Route
# ---------------------------------------------------------
@app.get("/")
def root():
    return {
        "status": "ONLINE",
        "engine": "NEURAL DATA ANALYSIS CORE"
    }


# ---------------------------------------------------------
# Keep-alive / warm-up ping — deliberately does NOTHING except return
# instantly. Call this from the app the moment it launches (and optionally
# on a repeating timer while the app stays open) so Render's free-tier
# spin-down doesn't cost you a 30-50s cold start the first time you press
# Scan, open the Report tab, or send a chat message. This route touches no
# pandas/sklearn/ADK code paths, so it wakes the dyno without doing any
# real work.
# ---------------------------------------------------------
@app.get("/ping")
def ping():
    return {"status": "awake"}


# ---------------------------------------------------------
# AI Routes — must be AFTER app is created
# ---------------------------------------------------------
from ai_routes import ai_router
app.include_router(ai_router)

# ---------------------------------------------------------
# Enterprise Analytics Platform extensions — must also be AFTER app is
# created, same as ai_router above. init_db() creates the new tables
# (datasets, dataset_columns, dataset_relationships, query_history) if they
# don't already exist; safe to call on every process start.
# ---------------------------------------------------------
init_db()
app.include_router(dataset_registry_router)
app.include_router(schema_intelligence_router)
app.include_router(query_history_router)
app.include_router(ingestion_router)
app.include_router(plan_cache_router)
app.include_router(sql_cache_router)
app.include_router(memory_engine_router)

# ─────────────────────────────────────────────────────────────────────────────
# InsightFlow Power BI adapter
# Uses the same cleaning, transformation, analytics and reporting modules as
# the Excel backend. Power BI sends DataView rows as JSON; no local files are
# required on the deployed service.
# ─────────────────────────────────────────────────────────────────────────────
from powerbi_routes import router as powerbi_router
app.include_router(powerbi_router)

# ─────────────────────────────────────────────────────────────────────────────
# Structured diagnostics for unmatched routes / method mismatches.
# Purely additive: every route defined above still returns whatever it
# already returned. This only replaces Starlette's plain-text default body
# for requests that hit NO route at all (typically a 404, or a 405 when the
# path exists but the HTTP method doesn't), so the InsightFlow visual can
# tell "route_not_found" apart from a transformation/validation failure
# instead of getting an opaque "Backend error".
# ─────────────────────────────────────────────────────────────────────────────
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.exceptions import RequestValidationError


@app.exception_handler(StarletteHTTPException)
async def structured_http_exception_handler(request, exc: StarletteHTTPException):
    if exc.status_code == 404:
        error_type = "route_not_found"
    elif exc.status_code == 405:
        error_type = "method_not_allowed"
    else:
        error_type = "http_error"
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "success": False,
            "error": {
                "type": error_type,
                "message": exc.detail if isinstance(exc.detail, str) else str(exc.detail),
                "endpoint": str(request.url.path),
            },
        },
    )


from fastapi.encoders import jsonable_encoder


@app.exception_handler(RequestValidationError)
async def structured_validation_exception_handler(request, exc: RequestValidationError):
    # Malformed / missing-field request bodies (e.g. Power BI visual sends
    # rows without columns, or a non-list rows field) -> HTTP 422. Same
    # envelope shape as every other /powerbi/* error, so the visual doesn't
    # need a special case for "the request itself was invalid" vs. "the
    # request was valid but processing it failed".
    return JSONResponse(
        status_code=422,
        content={
            "success": False,
            "error": {
                "type": "invalid_request",
                "message": "Request body failed validation.",
                "endpoint": str(request.url.path),
                "details": jsonable_encoder(exc.errors()),
            },
        },
    )
