from __future__ import annotations

import json
import os
import re
import traceback
from typing import Any, Optional

import numpy as np
import pandas as pd
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from data_cleaner import clean_dataframe
from powerbi_routes import router as powerbi_router

try:
    from google import genai
except Exception:
    genai = None

app = FastAPI(title="ElectricAI Power BI Backend", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

BLANK_LIKE_RE = re.compile(r"^[\s\u00A0\u200B\u200C\u200D\uFEFF\u00AD\u2060]*$")


class DatasetPayload(BaseModel):
    columns: list[str] = Field(default_factory=list)
    rows: list[list[Any]] = Field(default_factory=list)
    # Optional metadata supplied by the visual.
    source: str = "powerbi"
    title: Optional[str] = None


class CleanRequest(BaseModel):
    dataset: DatasetPayload
    config: dict[str, Any] = Field(default_factory=dict)


class QueryRequest(BaseModel):
    dataset: DatasetPayload
    text: str


class ReportRequest(BaseModel):
    dataset: DatasetPayload
    focus_analysis_types: list[dict[str, Any]] = Field(default_factory=list)


class ContextRequest(BaseModel):
    profile: dict[str, Any]
    selected_ids: list[str] = Field(default_factory=list)
    analysis_titles: list[str] = Field(default_factory=list)


def normalize_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    for col in df.select_dtypes(include=["object"]).columns:
        df[col] = df[col].apply(lambda v: v.strip() if isinstance(v, str) else v)
        df[col] = df[col].apply(
            lambda v: np.nan if isinstance(v, str) and BLANK_LIKE_RE.match(v) else v
        )
    return df


def dataframe_from_payload(payload: DatasetPayload) -> pd.DataFrame:
    if not payload.columns:
        return pd.DataFrame()
    rows = payload.rows or []
    width = len(payload.columns)
    normalized_rows = []
    for row in rows:
        row = list(row)
        if len(row) < width:
            row += [None] * (width - len(row))
        normalized_rows.append(row[:width])
    df = pd.DataFrame(normalized_rows, columns=payload.columns)
    return normalize_dataframe(df)


def json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [json_safe(v) for v in value]
    if isinstance(value, tuple):
        return [json_safe(v) for v in value]
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating,)):
        return float(value) if np.isfinite(value) else None
    if isinstance(value, (np.bool_,)):
        return bool(value)
    if pd.isna(value):
        return None
    return value


def analyze_dataframe(df: pd.DataFrame) -> dict[str, Any]:
    numeric = df.select_dtypes(include=np.number)
    missing = {c: int(df[c].isna().sum()) for c in df.columns}
    unique = {c: int(df[c].nunique(dropna=True)) for c in df.columns}
    profile = []
    for c in df.columns:
        s = df[c]
        item: dict[str, Any] = {
            "column": c,
            "dtype": str(s.dtype),
            "missing": int(s.isna().sum()),
            "missing_pct": round(float(s.isna().mean() * 100), 2) if len(s) else 0,
            "unique": int(s.nunique(dropna=True)),
        }
        if pd.api.types.is_numeric_dtype(s):
            item.update({
                "min": json_safe(s.min()) if not s.dropna().empty else None,
                "max": json_safe(s.max()) if not s.dropna().empty else None,
                "mean": json_safe(s.mean()) if not s.dropna().empty else None,
                "median": json_safe(s.median()) if not s.dropna().empty else None,
            })
        profile.append(item)

    return json_safe({
        "rows": int(len(df)),
        "columns": int(len(df.columns)),
        "column_names": list(df.columns),
        "duplicates": int(df.duplicated().sum()),
        "missing_values": missing,
        "unique_values": unique,
        "numeric_columns": list(numeric.columns),
        "categorical_columns": [c for c in df.columns if c not in numeric.columns],
        "preview": df.head(25).astype(object).where(pd.notna(df.head(25)), "").to_dict(orient="records"),
        "profile": profile,
    })


def dataset_json(df: pd.DataFrame) -> dict[str, Any]:
    return json_safe({
        "columns": list(df.columns),
        "rows": df.astype(object).where(pd.notna(df), None).to_dict(orient="records"),
        "row_count": int(len(df)),
    })


def recommend_charts(df: pd.DataFrame) -> list[dict[str, Any]]:
    nums = list(df.select_dtypes(include=np.number).columns)
    cats = [c for c in df.columns if c not in nums]
    out = []
    if cats and nums:
        out.append({"chart": "bar", "x_axis": cats[0], "y_axis": nums[0], "reason": "Categorical comparison of a numeric measure."})
    if len(nums) >= 2:
        out.append({"chart": "scatter", "x_axis": nums[0], "y_axis": nums[1], "reason": "Relationship between two numeric variables."})
    if nums:
        out.append({"chart": "line", "x_axis": cats[0] if cats else None, "y_axis": nums[0], "reason": "Trend or ordered progression when an ordered dimension exists."})
    return out[:3]


def local_query(df: pd.DataFrame, text: str) -> dict[str, Any]:
    q = text.lower().strip()
    numeric = list(df.select_dtypes(include=np.number).columns)
    categorical = [c for c in df.columns if c not in numeric]

    # Deterministic operations cover common Power BI requests without exposing raw SQL execution.
    if any(k in q for k in ["missing", "null", "blank"]):
        return {"action": "profile_missing", "result": [{"column": c, "missing": int(df[c].isna().sum())} for c in df.columns]}
    if "duplicate" in q:
        return {"action": "deduplicate", "result": {"duplicate_rows": int(df.duplicated().sum())}}
    if ("average" in q or "mean" in q) and numeric:
        col = next((c for c in numeric if c.lower() in q), numeric[0])
        return {"action": "aggregate", "operation": "average", "column": col, "value": json_safe(df[col].mean())}
    if ("sum" in q or "total" in q or "revenue" in q) and numeric:
        col = next((c for c in numeric if c.lower() in q), numeric[0])
        return {"action": "aggregate", "operation": "sum", "column": col, "value": json_safe(df[col].sum())}
    if ("top" in q or "highest" in q) and numeric:
        col = next((c for c in numeric if c.lower() in q), numeric[0])
        n = 10
        m = re.search(r"top\s+(\d+)", q)
        if m:
            n = max(1, min(100, int(m.group(1))))
        result = df.nlargest(n, col).head(n)
        return {"action": "top_n", "column": col, "n": n, "result": result.fillna("").to_dict(orient="records")}
    return {
        "action": "profile",
        "message": "I could not map the request to a deterministic operation yet. Here is the dataset profile.",
        "analysis": analyze_dataframe(df),
    }


def ai_report(df: pd.DataFrame, focus: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    analysis = analyze_dataframe(df)
    nums = analysis["numeric_columns"]
    findings = []
    if analysis["duplicates"]:
        findings.append(f"The dataset contains {analysis['duplicates']} duplicate rows.")
    total_missing = sum(analysis["missing_values"].values())
    if total_missing:
        findings.append(f"There are {total_missing} missing cells across the dataset.")
    for c in nums[:5]:
        s = df[c].dropna()
        if len(s):
            findings.append(f"{c}: mean {s.mean():.2f}, median {s.median():.2f}, range {s.min():.2f} to {s.max():.2f}.")
    if not findings:
        findings.append("No immediate data-quality issue was detected in the supplied Power BI data view.")
    return json_safe({
        "title": "Power BI Data Analysis Report",
        "focus_analysis_types": focus or [],
        "executive_summary": findings[:5],
        "data_quality": {
            "rows": analysis["rows"],
            "columns": analysis["columns"],
            "missing_cells": total_missing,
            "duplicate_rows": analysis["duplicates"],
        },
        "key_findings": findings,
        "chart_recommendations": recommend_charts(df),
        "profile": analysis,
    })


@app.get("/")
def root():
    return {"name": "ElectricAI Power BI Backend", "status": "ok", "version": "2.0.0"}


@app.get("/ping")
def ping():
    return {"status": "awake", "service": "powerbi"}


@app.post("/powerbi/analyze")
def powerbi_analyze(req: DatasetPayload):
    df = dataframe_from_payload(req)
    return {"success": True, "source": "powerbi", "analysis": analyze_dataframe(df)}


@app.post("/powerbi/clean_data")
def powerbi_clean(req: CleanRequest):
    df = dataframe_from_payload(req.dataset)
    config = {
        "standardize_cols": req.config.get("standardize_cols", True),
        "remove_duplicates": req.config.get("remove_duplicates", True),
        "remove_empty_rows": req.config.get("remove_empty_rows", True),
        "handle_missing_values": req.config.get("handle_missing_values", True),
        "null_strategy": req.config.get("null_strategy", "smart"),
        "normalize_text": req.config.get("normalize_text", True),
        "infer_types": req.config.get("infer_types", True),
        "handle_outliers": req.config.get("handle_outliers", False),
        "outlier_method": req.config.get("outlier_method", "cap"),
    }
    before = analyze_dataframe(df)
    cleaned, report = clean_dataframe(df, config)
    after = analyze_dataframe(cleaned)
    return json_safe({
        "success": True,
        "before": before,
        "after": after,
        "comparison": {
            "rows_removed": before["rows"] - after["rows"],
            "total_missing_before": sum(before["missing_values"].values()),
            "total_missing_after": sum(after["missing_values"].values()),
            "total_duplicates_before": before["duplicates"],
            "total_duplicates_after": after["duplicates"],
        },
        "cleaning_report": report.to_dict() if hasattr(report, "to_dict") else report,
        "cleaned_dataset": dataset_json(cleaned),
        "powerbi_note": "The custom visual can render this cleaned result, but a custom visual cannot write rows back into the underlying Power BI model. Persist the transformation in Power Query or another write-capable pipeline if permanent model changes are required.",
    })


@app.post("/powerbi/smart_query")
def powerbi_smart_query(req: QueryRequest):
    df = dataframe_from_payload(req.dataset)
    result = local_query(df, req.text)
    return {"success": True, "route": "powerbi", "operation": result, "analysis": analyze_dataframe(df)}


@app.post("/powerbi/analyze-report")
def powerbi_report(req: ReportRequest):
    df = dataframe_from_payload(req.dataset)
    return {"success": True, "report": ai_report(df, req.focus_analysis_types)}


@app.post("/powerbi/suggest_analysis_types")
def suggest_analysis_types(req: DatasetPayload):
    df = dataframe_from_payload(req)
    a = analyze_dataframe(df)
    nums = a["numeric_columns"]
    cats = a["categorical_columns"]
    suggestions = []
    if nums:
        suggestions.append({"id": "descriptive", "title": "Descriptive Analysis", "reason": "Numeric measures are available."})
    if cats and nums:
        suggestions.append({"id": "comparison", "title": "Category Comparison", "reason": "Categorical and numeric fields can be compared."})
    if len(nums) >= 2:
        suggestions.append({"id": "relationship", "title": "Relationship Analysis", "reason": "Multiple numeric measures are available."})
    if a["missing_values"] and sum(a["missing_values"].values()) > 0:
        suggestions.append({"id": "quality", "title": "Data Quality Analysis", "reason": "Missing values were detected."})
    return {"success": True, "suggestions": suggestions[:6], "profile": a}


@app.post("/powerbi/analysis_business_context")
def analysis_business_context(req: ContextRequest):
    return {
        "success": True,
        "selected": req.selected_ids,
        "business_problems": [
            {"analysis_id": sid, "title": title, "problems": [
                "What are the main patterns in this dataset?",
                "Which categories or measures require attention?",
                "Where are the largest opportunities or anomalies?",
            ]}
            for sid, title in zip(req.selected_ids, req.analysis_titles)
        ],
    }


@app.post("/powerbi/analyze-report-focused")
def powerbi_report_focused(req: ReportRequest):
    df = dataframe_from_payload(req.dataset)
    return {"success": True, "report": ai_report(df, req.focus_analysis_types)}


@app.post("/powerbi/chart_recommendations")
def chart_recommendations(req: DatasetPayload):
    df = dataframe_from_payload(req)
    return {"success": True, "recommendations": recommend_charts(df)}


@app.get("/health")
def health():
    return {"status": "healthy", "service": "electricai-powerbi"}


# Power BI dataset/pipeline API routes
app.include_router(powerbi_router)
