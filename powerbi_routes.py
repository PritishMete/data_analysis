from __future__ import annotations

import copy
import re
import uuid
from typing import Any

import pandas as pd
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from data_cleaner import DataCleaner

router = APIRouter()

# In-memory sessions are intentional for the Power BI visual. The visual sends
# the dataset with each request, so the server does not need local files.
SESSIONS: dict[str, dict[str, Any]] = {}

TRANSFORMATIONS = [
    {"id": "standardize_columns", "name": "standardize_columns", "display_name": "Standardize column names"},
    {"id": "remove_duplicates", "name": "remove_duplicates", "display_name": "Remove duplicates"},
    {"id": "remove_empty_rows", "name": "remove_empty_rows", "display_name": "Remove empty rows"},
    {"id": "handle_missing_values", "name": "handle_missing_values", "display_name": "Handle missing values"},
    {"id": "normalize_text", "name": "normalize_text", "display_name": "Normalize text"},
    {"id": "infer_types", "name": "infer_types", "display_name": "Infer data types"},
    {"id": "handle_outliers", "name": "handle_outliers", "display_name": "Handle outliers"},
    {"id": "filter_rows", "name": "filter_rows", "display_name": "Filter rows"},
]


class SessionRequest(BaseModel):
    columns: list[str] = Field(default_factory=list)
    rows: list[list[Any]] = Field(default_factory=list)


class DatasetRequest(SessionRequest):
    session_id: str | None = None


class TransformRequest(DatasetRequest):
    transformation_name: str | None = None
    query: str | None = None
    params: dict[str, Any] = Field(default_factory=dict)


def _df(columns: list[str], rows: list[list[Any]]) -> pd.DataFrame:
    width = len(columns)
    fixed = []
    for row in rows or []:
        values = list(row)
        values += [None] * max(0, width - len(values))
        fixed.append(values[:width])
    return pd.DataFrame(fixed, columns=columns)


def _export(df: pd.DataFrame) -> dict[str, Any]:
    clean = df.astype(object).where(pd.notna(df), None)
    return {"columns": [str(c) for c in clean.columns], "rows": clean.values.tolist(), "row_count": len(clean)}


def _profile(df: pd.DataFrame) -> dict[str, Any]:
    return {
        "rows": int(len(df)),
        "columns": int(len(df.columns)),
        "column_names": [str(c) for c in df.columns],
        "missing_values": {str(c): int(df[c].isna().sum()) for c in df.columns},
        "duplicates": int(df.duplicated().sum()) if len(df.columns) else 0,
    }


def _session(req: TransformRequest) -> dict[str, Any]:
    sid = req.session_id
    if not sid:
        sid = str(uuid.uuid4())
    state = SESSIONS.setdefault(sid, {"history": [], "future": []})
    if req.columns:
        state["columns"] = list(req.columns)
        state["rows"] = copy.deepcopy(req.rows)
    return state


def _query_to_step(query: str | None, params: dict[str, Any]) -> dict[str, Any] | None:
    q = (query or "").strip()
    if not q:
        return None
    low = q.lower()

    if "standardize" in low or "lowercase" in low and ("column" in low or "header" in low):
        return {"op": "standardize_columns"}
    if "duplicate" in low:
        return {"op": "remove_duplicates"}
    if "empty row" in low or "blank row" in low:
        return {"op": "remove_empty_rows"}
    if "missing" in low or "null" in low or "blank value" in low:
        return {"op": "handle_missing_values", "strategy": params.get("strategy", "smart")}
    if "normalize" in low and "text" in low:
        return {"op": "normalize_text"}
    if "infer" in low and "type" in low:
        return {"op": "infer_types"}
    if "outlier" in low:
        return {"op": "handle_outliers", "method": params.get("method", "cap")}

    # Examples: filter sales > 100, filter rows where amount is greater than 100
    patterns = [
        r"(?:where|filter)\s+(?:rows?\s+where\s+)?['\"]?([^'\"\s]+)['\"]?\s*(>=|<=|!=|=|>|<)\s*['\"]?([^'\"]+)['\"]?",
    ]
    for pattern in patterns:
        m = re.search(pattern, low)
        if m:
            col, op, value = m.groups()
            value = value.strip()
            try:
                value = float(value)
                if value.is_integer():
                    value = int(value)
            except ValueError:
                pass
            op_map = {"=": "equals", "!=": "not_equals", ">": "greater_than", "<": "less_than", ">=": "greater_than_equal", "<=": "less_than_equal"}
            return {"op": "filter_rows", "column": col, "operator": op_map[op], "value": value}
    return None


def _step(req: TransformRequest) -> dict[str, Any] | None:
    name = (req.transformation_name or "").strip().lower()
    p = req.params or {}
    if name in {t["name"] for t in TRANSFORMATIONS}:
        if name == "filter_rows":
            return {
                "op": "filter_rows",
                "column": p.get("column"),
                "operator": p.get("operator", "not_equals"),
                "value": p.get("value"),
            }
        if name == "handle_missing_values":
            return {"op": name, "strategy": p.get("strategy", "smart"), "columns": p.get("columns")}
        if name == "handle_outliers":
            return {"op": name, "method": p.get("method", "cap")}
        return {"op": name}
    return _query_to_step(req.query, p)


def _run(req: TransformRequest, action: str) -> dict[str, Any]:
    state = _session(req)
    df = _df(req.columns, req.rows)
    before = _profile(df)

    if action == "undo":
        if not state["history"]:
            return {"success": False, "message": "Nothing to undo.", "session_id": req.session_id}
        state["future"].append(state["history"].pop())
        previous = state["history"][-1] if state["history"] else {"columns": req.columns, "rows": req.rows}
        out = _df(previous["columns"], previous["rows"])
        state["columns"], state["rows"] = _export(out)["columns"], _export(out)["rows"]
        return {"success": True, "session_id": req.session_id, "export": _export(out), "profile": _profile(out), "message": "Undo completed."}

    if action == "redo":
        if not state["future"]:
            return {"success": False, "message": "Nothing to redo.", "session_id": req.session_id}
        target = state["future"].pop()
        state["history"].append({"columns": target["columns"], "rows": target["rows"]})
        out = _df(target["columns"], target["rows"])
        state["columns"], state["rows"] = target["columns"], target["rows"]
        return {"success": True, "session_id": req.session_id, "export": _export(out), "profile": _profile(out), "message": "Redo completed."}

    step = _step(req)
    if not step or not step.get("op"):
        return {"success": False, "session_id": req.session_id, "message": "No valid transformation was supplied."}

    # Resolve case-insensitive column names for filter_rows.
    if step.get("op") == "filter_rows":
        wanted = str(step.get("column") or "")
        match = next((c for c in df.columns if str(c).lower() == wanted.lower()), None)
        if match is None:
            return {"success": False, "session_id": req.session_id, "message": f"Column not found: {wanted}"}
        step["column"] = match
        if step.get("value") is None:
            return {"success": False, "session_id": req.session_id, "message": "Filter requires a value."}

    cleaner = DataCleaner(df)
    cleaner.run_steps([step])
    out = cleaner.get_cleaned_dataframe()
    report = cleaner.get_report_dict()
    after = _profile(out)

    result = {
        "success": True,
        "session_id": req.session_id,
        "transformation": step,
        "before": before,
        "after": after,
        "report": report,
        "export": _export(out),
        "message": f"Transformation '{step['op']}' completed.",
    }

    if action == "apply":
        state["history"].append({"columns": before["column_names"], "rows": _export(df)["rows"]})
        state["future"] = []
        state["columns"], state["rows"] = _export(out)["columns"], _export(out)["rows"]
    return result


@router.get("/powerbi/ping")
def powerbi_ping():
    return {"status": "awake", "service": "powerbi", "pipeline": True, "version": "3.0.0"}


@router.get("/powerbi/health")
def powerbi_health():
    return {"status": "healthy", "service": "powerbi", "pipeline": True}


@router.get("/powerbi/version")
def powerbi_version():
    return {"service": "powerbi", "version": "3.0.0", "pipeline": True, "transformations": len(TRANSFORMATIONS)}


@router.get("/powerbi/transform/list")
def transform_list():
    return {"success": True, "transformations": TRANSFORMATIONS}


@router.post("/powerbi/session")
def create_session(req: SessionRequest):
    sid = str(uuid.uuid4())
    export = _export(_df(req.columns, req.rows))
    SESSIONS[sid] = {"history": [], "future": [], "columns": export["columns"], "rows": export["rows"]}
    return {"success": True, "session_id": sid, "profile": _profile(_df(req.columns, req.rows))}


@router.post("/powerbi/profile")
def profile(req: DatasetRequest):
    return {"success": True, "profile": _profile(_df(req.columns, req.rows))}


@router.post("/powerbi/transform/preview")
def transform_preview(req: TransformRequest):
    return _run(req, "preview")


@router.post("/powerbi/transform/apply")
def transform_apply(req: TransformRequest):
    return _run(req, "apply")


@router.post("/powerbi/transform/undo")
def transform_undo(req: TransformRequest):
    return _run(req, "undo")


@router.post("/powerbi/transform/redo")
def transform_redo(req: TransformRequest):
    return _run(req, "redo")
