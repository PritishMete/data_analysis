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


def _missing_mask(series: pd.Series) -> pd.Series:
    """Treat nulls and whitespace-only strings as missing without mutating data."""
    return series.isna() | series.astype("string").str.strip().eq("")


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


def _logical_type(name: str, series: pd.Series) -> tuple[str, int]:
    """Infer a logical type without changing the supplied values."""
    non_null = series[~_missing_mask(series)]
    if pd.api.types.is_bool_dtype(series):
        return "boolean", 0
    if not len(non_null):
        return "unknown", 0
    text = non_null.map(lambda value: str(value).strip())
    if text.str.casefold().isin({"true", "false", "yes", "no"}).all():
        return "boolean-like", 0
    low = name.casefold()
    if any(hint in low for hint in _DATE_HINTS):
        parsed = pd.to_datetime(text, errors="coerce")
        invalid = int(parsed.isna().sum())
        return "datetime", invalid
    numeric = pd.to_numeric(text, errors="coerce")
    if numeric.notna().all():
        return ("integer" if (numeric % 1 == 0).all() else "decimal"), 0
    return "text", 0


def profile_dataframe(df: pd.DataFrame) -> dict[str, Any]:
    """Return a compact, evidence-based profile for one dataset."""
    rows = int(len(df))
    columns = [str(c) for c in df.columns]
    schema: list[dict[str, Any]] = []
    primary_candidates: list[str] = []
    business_candidates: list[str] = []
    foreign_candidates: list[str] = []
    suspicious: list[dict[str, Any]] = []
    inconsistencies: list[dict[str, Any]] = []

    for name in columns:
        series = df[name]
        missing_mask = _missing_mask(series)
        non_null = series[~missing_mask]
        unique = int(non_null.nunique())
        missing = int(missing_mask.sum())
        role = _role(name, series)
        non_null_text = non_null.map(_text)
        raw_text = non_null.map(lambda value: str(value))
        samples = list(dict.fromkeys(non_null_text.head(3).tolist()))
        business_key = bool(
            rows > 0
            and missing == 0
            and (role == "identifier" or (role == "categorical" and unique == rows))
        )
        key_candidate = bool(business_key and unique == rows)
        if business_key:
            business_candidates.append(name)
        if key_candidate:
            primary_candidates.append(name)
        if role == "identifier" and not key_candidate:
            foreign_candidates.append(name)

        schema.append({
            "column": name,
            "dtype": _logical_type(name, series)[0],
            "physical_dtype": _display_dtype(series),
            "logical_type": _logical_type(name, series)[0],
            "pandas_dtype": str(series.dtype),
            "role": role,
            "non_null": int(len(non_null)),
            "missing": missing,
            "unique": unique,
            "key_candidate": key_candidate,
            "business_key_candidate": business_key,
            "primary_key_valid": key_candidate,
            "sample_values": samples,
        })

        low = name.casefold()
        logical_type, invalid_logical = _logical_type(name, series)
        if invalid_logical:
            suspicious.append({"column": name, "issue": f"{invalid_logical} non-null value(s) cannot be parsed as {logical_type}.", "classification": "invalid"})
        if missing:
            suspicious.append({"column": name, "issue": f"{missing} missing value(s).", "classification": "observed fact"})
        if pd.api.types.is_numeric_dtype(series) and any(h in low for h in ("amount", "price", "sales", "revenue", "profit", "quantity", "qty")):
            negative = int((series.dropna() < 0).sum())
            if negative:
                suspicious.append({"column": name, "issue": f"{negative} negative measure value(s); verify whether they are valid returns/adjustments.", "classification": "suspicious"})
        if unique == 1 and rows > 1:
            suspicious.append({"column": name, "issue": "Constant value across all non-empty records.", "classification": "suspicious"})

        grouped: dict[str, set[str]] = defaultdict(set)
        for value in raw_text:
            if value.strip():
                grouped[" ".join(value.casefold().split())].add(value)
        variants = [sorted(values) for values in grouped.values() if len(values) > 1]
        if variants and role == "categorical":
            inconsistencies.append({"column": name, "variants": variants[:20], "issue": "Values differ only by case or whitespace."})

    grain = "One row per observed record in the scanned worksheet."
    if business_candidates:
        grain += f" Intended row key candidate: {business_candidates[0]}."
        if business_candidates[0] not in primary_candidates:
            grain += " The candidate is not physically unique in the supplied rows."
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
        "business_key_candidates": business_candidates,
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
        "quality_summary": {
            "exact_duplicate_rows": int(df.duplicated().sum()),
            "exact_duplicate_groups": int(df.astype(str).value_counts().gt(1).sum()) if rows else 0,
        },
    }
