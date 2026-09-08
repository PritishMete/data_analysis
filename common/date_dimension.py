"""Deterministic, read-only calendar dimension creation from a cleaned fact."""

from __future__ import annotations

from typing import Any

import pandas as pd


def _json_rows(frame: pd.DataFrame) -> list[dict[str, Any]]:
    rows = []
    for row in frame.to_dict(orient="records"):
        converted = {}
        for column, value in row.items():
            if value is pd.NA or (isinstance(value, float) and pd.isna(value)):
                converted[str(column)] = None
            elif hasattr(value, "item"):
                converted[str(column)] = value.item()
            else:
                converted[str(column)] = value
        rows.append(converted)
    return rows


def _parse_dates(series: pd.Series) -> pd.Series:
    try:
        return pd.to_datetime(series, errors="coerce", format="mixed")
    except (TypeError, ValueError):
        return pd.to_datetime(series, errors="coerce")


def _date_column(fact: pd.DataFrame, metadata: dict[str, Any]) -> str | None:
    declared = metadata.get("date_handling", {}).get("column")
    if declared in fact.columns:
        return declared
    parsed = next((column for column in fact.columns if str(column).endswith("_parsed")), None)
    if parsed:
        return str(parsed)[:-7]
    return next((str(column) for column in fact.columns if any(word in str(column).casefold() for word in ("date", "time", "timestamp"))), None)


def create_date_dimension(cleaned_fact: dict[str, Any]) -> dict[str, Any]:
    """Create dim_date only from the already-cleaned fact result."""
    table = cleaned_fact.get("cleaned_table")
    if not isinstance(table, dict) or not isinstance(table.get("rows"), list):
        return {"status": "BLOCKED", "error": "A cleaned Prompt 4 fact result is required; raw orders are not accepted as a fallback."}
    fact = pd.DataFrame(table["rows"], columns=table.get("columns"))
    if fact.empty and not table.get("columns"):
        return {"status": "BLOCKED", "error": "The cleaned fact has no schema."}
    date_column = _date_column(fact, cleaned_fact)
    if not date_column:
        return {"status": "BLOCKED", "error": "No semantic event date was available in the cleaned fact."}
    parsed_column = f"{date_column}_parsed"
    status_column = f"{date_column}_status"
    parsed = _parse_dates(fact[parsed_column] if parsed_column in fact else fact[date_column])
    valid = fact[status_column].astype(str).eq("VALID") & parsed.notna() if status_column in fact else parsed.notna()
    valid_dates = parsed.loc[valid].dt.normalize()
    unique_dates = pd.Series(sorted(valid_dates.dropna().unique()))
    dim = pd.DataFrame({"date": unique_dates})
    if not dim.empty:
        dim["date_key"] = dim["date"].map(lambda value: int(value.strftime("%Y%m%d")))
        dim["day"] = dim["date"].dt.day.astype(int)
        dim["month"] = dim["date"].dt.month.astype(int)
        dim["month_name"] = dim["date"].dt.month_name()
        dim["quarter"] = "Q" + dim["date"].dt.quarter.astype(str)
        dim["year"] = dim["date"].dt.year.astype(int)
    else:
        dim = pd.DataFrame(columns=["date", "date_key", "day", "month", "month_name", "quarter", "year"])
    dim = dim[["date_key", "date", "day", "month", "month_name", "quarter", "year"]]
    date_keys = pd.to_numeric(dim["date_key"], errors="coerce")
    checks = {
        "date_non_null": bool(dim["date"].notna().all()),
        "date_key_non_null": bool(dim["date_key"].notna().all()),
        "date_unique": bool(dim["date"].is_unique),
        "date_key_unique": bool(dim["date_key"].is_unique),
        "date_key_integer": bool(date_keys.dropna().map(lambda value: float(value).is_integer()).all()),
        "date_key_reversible": bool(dim.apply(lambda row: int(row["date"].strftime("%Y%m%d")) == int(row["date_key"]), axis=1).all()),
        "attributes_valid": bool(dim.apply(lambda row: row["day"] == row["date"].day and row["month"] == row["date"].month and row["month_name"] == row["date"].month_name() and row["quarter"] == f"Q{row['date'].quarter}" and row["year"] == row["date"].year, axis=1).all()),
        "sorted": bool(dim["date"].is_monotonic_increasing),
    }
    valid_key_set = set(dim["date_key"].tolist())
    fact_valid_keys = parsed.loc[valid].map(lambda value: int(value.strftime("%Y%m%d")))
    relationship = {
        "source_table": "fact_orders",
        "source_date_column": date_column,
        "target_table": "dim_date",
        "target_column": "date_key",
        "cardinality": "many -> one" if checks["date_key_unique"] else "not validated",
        "parent_key_unique": checks["date_key_unique"],
        "valid_fact_date_rows": int(valid.sum()),
        "invalid_or_unresolved_fact_date_rows": int((~valid).sum()),
        "orphan_valid_fact_dates": int((~fact_valid_keys.isin(valid_key_set)).sum()),
        "valid_fact_date_coverage": round(float(fact_valid_keys.isin(valid_key_set).mean()), 6) if len(fact_valid_keys) else 0.0,
        "unresolved_dates_unmatched": True,
    }
    status = "READY" if all(checks.values()) and relationship["orphan_valid_fact_dates"] == 0 else "BLOCKED"
    fact_with_key = fact.copy(deep=True)
    fact_with_key["date_key"] = fact_valid_keys.reindex(fact.index).where(valid)
    date_min = dim["date"].min().strftime("%Y-%m-%d") if not dim.empty else None
    date_max = dim["date"].max().strftime("%Y-%m-%d") if not dim.empty else None
    return {
        "success": True,
        "status": status,
        "source_fact": table.get("name", "fact_orders"),
        "date_field": date_column,
        "grain": "One row per unique observed valid calendar date.",
        "summary": {"clean_fact_rows": int(len(fact)), "valid_fact_date_rows": int(valid.sum()), "invalid_fact_date_rows_excluded": int((fact[status_column].astype(str).eq("INVALID")).sum()) if status_column in fact else int((~valid).sum()), "null_fact_date_rows_excluded": int((fact[status_column].astype(str).eq("NULL")).sum()) if status_column in fact else int(fact[date_column].isna().sum()), "unique_valid_dates": int(len(dim)), "dimension_rows": int(len(dim)), "earliest_date": date_min, "latest_date": date_max, "duplicate_date_keys": int(dim["date_key"].duplicated().sum()), "key_uniqueness_percent": 100.0 if checks["date_key_unique"] else 0.0},
        "validation": checks,
        "relationship": relationship,
        "audit_trail": [
            {"rule": "Use only Prompt 4 VALID fact dates", "affected_rows": int(valid.sum()), "source_field": date_column, "result": "Valid parsed dates selected; invalid and null dates excluded.", "validation_status": "PASS"},
            {"rule": "Deduplicate calendar dates", "affected_rows": int(valid.sum() - len(dim)), "source_field": date_column, "result": "One row per unique observed date.", "validation_status": "PASS"},
            {"rule": "Generate YYYYMMDD date_key", "affected_rows": int(len(dim)), "source_field": "date", "result": "Stable reversible integer key.", "validation_status": "PASS" if checks["date_key_reversible"] else "FAIL"},
            {"rule": "Derive day/month/month_name/quarter/year", "affected_rows": int(len(dim)), "source_field": "date", "result": "Deterministic calendar attributes.", "validation_status": "PASS" if checks["attributes_valid"] else "FAIL"},
            {"rule": "Sort ascending", "affected_rows": int(len(dim)), "source_field": "date", "result": "Ascending date and date_key order.", "validation_status": "PASS" if checks["sorted"] else "FAIL"},
        ],
        "star_schema_update": {"fact_table": "fact_orders", "dimensions": ["dim_customer", "dim_product", "dim_date", "dim_region"], "relationship": "dim_date 1 -> many fact_orders", "model_status": "READY FOR ANALYSIS" if status == "READY" else "BLOCKED"},
        "model_readiness": {"status": "READY FOR ANALYSIS" if status == "READY" else "BLOCKED", "next_step": "Proceed to Chapter 6 analysis using fact_orders, dim_customer, dim_product, dim_region, and dim_date." if status == "READY" else "Resolve dim_date validation failures before Chapter 6."},
        "fact_output": {"name": table.get("name", "fact_orders"), "rows": int(len(fact)), "columns": [str(column) for column in fact.columns], "date_key_derived_rows": int(valid.sum()), "source_fact_unchanged": bool(len(fact_with_key) == len(fact))},
        "cleaned_table": {"name": "dim_date", "columns": [str(column) for column in dim.columns], "rows": [{**row, "date": row["date"].strftime("%Y-%m-%d")} for row in _json_rows(dim)]},
        "preview": [{**row, "date": row["date"].strftime("%Y-%m-%d")} for row in _json_rows(dim.head(5))],
        "read_only": True,
    }
