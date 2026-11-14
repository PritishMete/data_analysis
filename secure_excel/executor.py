"""Execute structured Excel queries against a local pandas DataFrame."""

from __future__ import annotations

from typing import Any
import math

import pandas as pd

from common.statistics.service import calculate_data_quality_score


def _resolve_column(schema: dict[str, Any], column_id: str) -> str:
    mapping = schema.get("id_to_original", {})
    if column_id not in mapping:
        raise KeyError(f"Unknown column_id {column_id!r}")
    return mapping[column_id]


def _resolve_role(schema: dict[str, Any], column_id: str) -> str:
    for column in schema.get("columns", []):
        if column["column_id"] == column_id:
            return column["role"]
    raise KeyError(f"Unknown column_id {column_id!r}")


def _json_safe_value(value: Any) -> Any:
    if value is pd.NA or value is pd.NaT:
        return None
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    if pd.isna(value):
        return None
    if hasattr(value, "item"):
        return value.item()
    return value


def _json_safe_records(df: pd.DataFrame) -> list[dict[str, Any]]:
    records = df.to_dict(orient="records")
    return [
        {str(key): _json_safe_value(value) for key, value in row.items()}
        for row in records
    ]


def _to_bool_series(series: pd.Series) -> pd.Series:
    normalized = series.astype(str).str.strip().str.lower()
    truthy = {"true", "1", "yes", "y", "available", "open", "on", "enabled"}
    falsy = {"false", "0", "no", "n", "not available", "closed", "off", "disabled"}
    mapped = normalized.map(lambda value: True if value in truthy else False if value in falsy else pd.NA)
    return mapped.astype("boolean")


def _apply_condition(df: pd.DataFrame, schema: dict[str, Any], condition: dict[str, Any]) -> pd.Series:
    column = _resolve_column(schema, condition["column_id"])
    role = _resolve_role(schema, condition["column_id"])
    operator = condition["operator"]
    series = df[column]
    value = condition.get("value")
    value2 = condition.get("value2")

    if operator == "equals":
        if role in {"boolean_capability", "delivery_capability", "table_booking_capability"}:
            return _to_bool_series(series).fillna(False).eq(bool(value))
        return series.astype(object).eq(value)
    if operator == "not_equals":
        if role in {"boolean_capability", "delivery_capability", "table_booking_capability"}:
            return ~_to_bool_series(series).fillna(False).eq(bool(value))
        return ~series.astype(object).eq(value)
    if operator == "contains":
        return series.astype(str).str.contains(str(value), case=False, na=False)
    if operator == "starts_with":
        return series.astype(str).str.startswith(str(value), na=False)
    if operator == "ends_with":
        return series.astype(str).str.endswith(str(value), na=False)

    numeric = pd.to_numeric(series, errors="coerce")
    if operator == "greater_than":
        return numeric > float(value)
    if operator == "less_than":
        return numeric < float(value)
    if operator == "greater_equal":
        return numeric >= float(value)
    if operator == "less_equal":
        return numeric <= float(value)
    if operator == "between":
        return numeric.between(float(value), float(value2))
    if operator == "is_null":
        return series.isna()
    if operator == "is_not_null":
        return ~series.isna()
    raise ValueError(f"Unsupported operator {operator!r}")


def _preview_df(df: pd.DataFrame, limit: int = 25) -> dict[str, Any]:
    preview = df.head(limit)
    return {
        "columns": [str(col) for col in df.columns],
        "rows": _json_safe_records(preview),
        "row_count": int(len(df)),
    }


def _missing_by_column(df: pd.DataFrame) -> dict[str, int]:
    missing: dict[str, int] = {}
    for column in df.columns:
        series = df[column]
        mask = series.isna()
        if pd.api.types.is_object_dtype(series) or pd.api.types.is_string_dtype(series):
            mask = mask | series.astype(str).str.strip().eq("")
        count = int(mask.sum())
        if count:
            missing[str(column)] = count
    return missing


def _duplicate_identifier_report(
    df: pd.DataFrame,
    schema: dict[str, Any],
    identifier_column_id: str | None,
) -> dict[str, Any]:
    if not identifier_column_id:
        return {
            "status": "identifier_not_selected",
            "message": "No unique identifier column was selected for duplicate-ID analysis.",
            "column": None,
            "duplicate_value_count": 0,
            "duplicate_row_count": 0,
            "values": [],
        }

    column = _resolve_column(schema, identifier_column_id)
    series = df[column]
    normalized = series.map(lambda value: value.strip() if isinstance(value, str) else value)
    duplicate_mask = normalized.notna() & normalized.duplicated(keep=False)
    duplicate_values = normalized.loc[duplicate_mask].value_counts(dropna=False)
    values = [value.item() if hasattr(value, "item") else value for value in duplicate_values.index.tolist()]
    return {
        "status": "ok",
        "column": column,
        "duplicate_value_count": int(len(duplicate_values)),
        "duplicate_row_count": int(duplicate_mask.sum()),
        "values": values,
    }


def _execute_quality_check(df: pd.DataFrame, schema: dict[str, Any], query: dict[str, Any]) -> dict[str, Any]:
    """Run a read-only profile; never mutates the source DataFrame."""
    quality = calculate_data_quality_score(df)
    identifier = _duplicate_identifier_report(df, schema, query.get("identifier_column_id"))
    return {
        "operation": "quality_check",
        "result": {
            "quality_score": quality["quality_score"],
            "quality_grade": quality["quality_grade"],
            "quality_summary": quality["quality_summary"],
            "row_count": int(len(df)),
            "column_count": int(len(df.columns)),
            "missing_by_column": _missing_by_column(df),
            "duplicate_rows": int(df.duplicated(keep=False).sum()),
            "duplicate_identifier": identifier,
            "source_mutated": False,
        },
    }


def execute_structured_query(df: pd.DataFrame, schema: dict[str, Any], query: dict[str, Any]) -> dict[str, Any]:
    operation = query["operation"]
    working = df.copy()

    if query.get("conditions"):
        mask = pd.Series(True, index=working.index)
        for condition in query["conditions"]:
            mask &= _apply_condition(working, schema, condition)
        working = working.loc[mask]

    if operation == "quality_check":
        return _execute_quality_check(working, schema, query)

    if operation == "filter":
        return {"operation": "filter", "result": _preview_df(working)}

    if operation == "sort":
        sort_spec = query.get("sort") or []
        by = [_resolve_column(schema, item["column_id"]) for item in sort_spec]
        ascending = [item.get("direction", "asc") != "desc" for item in sort_spec]
        working = working.sort_values(by=by, ascending=ascending)
        return {"operation": "sort", "result": _preview_df(working)}

    if operation == "count":
        return {"operation": "count", "result": {"count": int(len(working))}}

    if operation in {"group", "aggregate", "report"}:
        if query.get("group_by"):
            group_cols = [_resolve_column(schema, column_id) for column_id in query["group_by"]]
            grouped = working.groupby(group_cols, dropna=False)
            rows: list[dict[str, Any]] = []
            aggregates = query.get("aggregates") or []
            if aggregates:
                agg_map: dict[str, tuple[str, str]] = {}
                for aggregate in aggregates:
                    column = _resolve_column(schema, aggregate["column_id"])
                    alias = aggregate.get("alias") or column
                    func = aggregate.get("function", "count")
                    if func == "count":
                        agg_map[alias] = (column, "count")
                    elif func in {"sum", "avg", "min", "max"}:
                        agg_map[alias] = (column, func)
                    else:
                        raise ValueError(f"Unsupported aggregate function {func!r}")
                computed = grouped.agg(**{
                    alias: pd.NamedAgg(column=column, aggfunc=func)
                    for alias, (column, func) in agg_map.items()
                })
                computed = computed.reset_index()
                rows = _json_safe_records(computed)
            else:
                computed = grouped.size().reset_index(name="count")
                rows = _json_safe_records(computed)
            return {
                "operation": operation,
                "result": {
                    "columns": list(rows[0].keys()) if rows else [],
                    "rows": rows,
                    "row_count": len(rows),
                },
            }

        return {"operation": operation, "result": _preview_df(working)}

    raise ValueError(f"Unsupported operation {operation!r}")
