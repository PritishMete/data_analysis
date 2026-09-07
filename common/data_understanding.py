"""Deterministic data-understanding profile for a scanned worksheet.

This module describes the observed shape and quality of one dataset. It does
not clean values, infer business facts as certainty, or expose row samples.
"""

from __future__ import annotations

from collections import defaultdict
import re
from typing import Any

import pandas as pd


_ID_RE = re.compile(r"(^|[_\s-])(id|key|code)$|(^|[_\s-])(id|key|code)[_\s-]", re.I)
_DATE_HINTS = ("date", "time", "timestamp", "month", "year", "day")
_TEXT_HINTS = ("review", "comment", "feedback", "description", "message", "note", "text")
_CATEGORY_HINTS = ("country", "region", "city", "gender", "status", "type", "category", "segment", "class")
_MEASURE_HINTS = ("amount", "price", "sales", "revenue", "profit", "cost", "quantity", "qty", "count", "total", "rating", "score", "age")
_GEO_HINTS = ("latitude", "longitude", "lat", "long", "lng", "coordinate")


def _text(value: Any) -> str:
    return "" if value is None or (isinstance(value, float) and pd.isna(value)) else str(value).strip()


def _role(name: str, series: pd.Series) -> str:
    low = name.casefold().replace("_", " ").replace("-", " ")
    if any(h in low for h in _GEO_HINTS):
        return "geographic_coordinate"
    if any(h in low for h in _DATE_HINTS):
        return "datetime"
    if any(h in low for h in _TEXT_HINTS):
        return "free_text"
    if _ID_RE.search(low) or low.endswith(("id", "key", "code")) or low in {"id", "key", "code"}:
        return "identifier"
    if any(h in low for h in _CATEGORY_HINTS):
        return "categorical"
    if pd.api.types.is_bool_dtype(series):
        return "categorical"
    if pd.api.types.is_numeric_dtype(series):
        return "numeric_measure"
    non_null = series.dropna().map(_text)
    avg_len = float(non_null.str.len().mean()) if not non_null.empty else 0.0
    unique_ratio = float(non_null.nunique() / len(non_null)) if len(non_null) else 0.0
    if avg_len > 45 or unique_ratio > 0.8:
        return "free_text"
    return "categorical"


def _display_dtype(series: pd.Series) -> str:
    if pd.api.types.is_bool_dtype(series):
        return "boolean"
    if pd.api.types.is_numeric_dtype(series):
        return "numeric"
    if pd.api.types.is_datetime64_any_dtype(series):
        return "datetime"
    return "text"


def profile_dataframe(df: pd.DataFrame) -> dict[str, Any]:
    """Return a compact, evidence-based profile for one dataset."""
    rows = int(len(df))
    columns = [str(c) for c in df.columns]
    schema: list[dict[str, Any]] = []
    primary_candidates: list[str] = []
    foreign_candidates: list[str] = []
    suspicious: list[dict[str, Any]] = []
    inconsistencies: list[dict[str, Any]] = []

    for name in columns:
        series = df[name]
        non_null = series.dropna()
        unique = int(non_null.nunique())
        missing = int(series.isna().sum())
        role = _role(name, series)
        non_null_text = non_null.map(_text)
        samples = list(dict.fromkeys(non_null_text.head(3).tolist()))
        key_candidate = bool(rows > 0 and missing == 0 and unique == rows and role in {"identifier", "categorical"})
        if key_candidate:
            primary_candidates.append(name)
        if role == "identifier" and not key_candidate:
            foreign_candidates.append(name)

        schema.append({
            "column": name,
            "dtype": _display_dtype(series),
            "pandas_dtype": str(series.dtype),
            "role": role,
            "non_null": int(len(non_null)),
            "missing": missing,
            "unique": unique,
            "key_candidate": key_candidate,
            "sample_values": samples,
        })

        low = name.casefold()
        if missing:
            suspicious.append({"column": name, "issue": f"{missing} missing value(s)."})
        if pd.api.types.is_numeric_dtype(series) and any(h in low for h in ("amount", "price", "sales", "revenue", "profit", "quantity", "qty")):
            negative = int((series.dropna() < 0).sum())
            if negative:
                suspicious.append({"column": name, "issue": f"{negative} negative measure value(s); verify whether they are valid returns/adjustments."})
        if unique == 1 and rows > 1:
            suspicious.append({"column": name, "issue": "Constant value across all non-empty records."})

        grouped: dict[str, set[str]] = defaultdict(set)
        for value in non_null_text:
            if value:
                grouped[" ".join(value.casefold().split())].add(value)
        variants = [sorted(values) for values in grouped.values() if len(values) > 1]
        if variants and role == "categorical":
            inconsistencies.append({"column": name, "variants": variants[:8], "issue": "Values differ only by case or whitespace."})

    grain = "One row per observed record in the scanned worksheet."
    if primary_candidates:
        grain += f" Candidate row key: {primary_candidates[0]}."
    else:
        grain += " No reliable single-column row key was observed."

    measure_columns = [entry["column"] for entry in schema if entry["role"] == "numeric_measure"]
    dimension_columns = [entry["column"] for entry in schema if entry["role"] in {"categorical", "datetime", "identifier"}]
    fact = "Use the scanned table as the fact table if each row represents a business event or transaction."
    if not measure_columns:
        fact = "No clear numeric measures were observed; treat this as a descriptive entity table until business grain is confirmed."

    return {
        "dataset_overview": {"rows": rows, "columns": len(columns), "grain": grain},
        "schema": schema,
        "primary_key_candidates": primary_candidates,
        "foreign_key_candidates": foreign_candidates,
        "relationships": ["Relationships to other tables cannot be verified from one scanned worksheet."],
        "invalid_or_suspicious_values": suspicious,
        "categorical_inconsistencies": inconsistencies,
        "fact_table_recommendation": fact,
        "dimension_table_recommendation": [
            f"Candidate dimensions are categorical, date, and identifier fields: {', '.join(dimension_columns) or 'none observed'}.",
            "Confirm business ownership and grain before splitting the worksheet into separate dimensions.",
        ],
        "star_schema": {
            "fact_table": "Fact_ScannedDataset" if measure_columns else "Not yet determined",
            "measures": measure_columns,
            "dimensions": dimension_columns,
            "relationships": "Join dimensions to the fact table through verified keys only.",
        },
        "assumptions": [
            "The first row supplied by Excel is the header row.",
            "The scanned worksheet represents one logical dataset, not multiple stacked tables.",
            "Key and relationship candidates are hypotheses and require business confirmation.",
        ],
    }
