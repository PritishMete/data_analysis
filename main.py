import re

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
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

from ai_analyst import generate_report, suggest_analysis_types, explain_business_problems

app = FastAPI()

# Allow Flutter/Web requests
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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
# Helper Function
# ---------------------------------------------------------
def analyze_dataframe(df: pd.DataFrame):
    try:
        describe_data = (
            df.describe(include='all')
            .fillna("")
            .reset_index()
            .to_dict(orient="records")
        )
    except Exception:
        describe_data = []
    preview = df.head(15).fillna("").to_dict(orient="records")
    sample = (
        df.sample(min(10, len(df)))
        .fillna("")
        .to_dict(orient="records")
        if len(df) > 0 else []
    )
    missing_values = {
        col: int(df[col].isnull().sum())
        for col in df.columns
    }
    unique_values = {
        col: int(df[col].nunique())
        for col in df.columns
    }
    duplicate_count = int(df.duplicated().sum())
    buffer = io.StringIO()
    df.info(buf=buffer)
    info_text = buffer.getvalue()
    return {
        "rows": int(df.shape[0]),
        "columns": int(df.shape[1]),
        "column_names": list(df.columns),
        "duplicates": duplicate_count,
        "missing_values": missing_values,
        "unique_values": unique_values,
        "preview": preview,
        "sample": sample,
        "describe": describe_data,
        "info": info_text
    }


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
        df = pd.read_csv(io.BytesIO(contents))
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
# API Route — raw stats (existing)
# ---------------------------------------------------------
@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
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
        df = _load_dataframe(file.filename, contents)
        result = analyze_dataframe(df)
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
async def analyze_report(file: UploadFile = File(...)):
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
        result = await generate_report(df)
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
            "rows_removed": before_analysis["rows"] - after_analysis["rows"],
            "columns_removed": before_analysis["columns"] - after_analysis["columns"],
            "total_missing_before": sum(before_analysis["missing_values"].values()),
            "total_missing_after": sum(after_analysis["missing_values"].values()),
            "total_duplicates_before": before_analysis["duplicates"],
            "total_duplicates_after": after_analysis["duplicates"],
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
            "summary": f"✅ Cleaned data: {after_analysis['rows']} rows × {after_analysis['columns']} columns. "
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
):
    """
    Same as /analyze-report, but accepts the analysis type(s) the user
    selected (JSON-encoded list of {"id","title"} dicts) so the final
    report's 'Key Findings' section can be weighted toward what the user
    actually asked for, instead of a fully generic report.
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

    try:
        result = await generate_report(df, focus_analysis_types=focus_list or None)
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
    """
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
    except ValueError as e:
        return {"error": str(e)}

    try:
        sheets = json.loads(available_sheets)
    except json.JSONDecodeError:
        sheets = []

    try:
        result = await handle_smart_query(text, df, sheets)
        return result
    except Exception as e:
        print("[/smart_query] EXCEPTION:")
        traceback.print_exc()
        return {
            "route": "unknown",
            "success": False,
            "error": str(e),
            "message": f"Error: {str(e)}",
            "operation": None,
            "result": None,
        }


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
