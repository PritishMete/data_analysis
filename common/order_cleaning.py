"""Generic, read-only fact/event cleaning for Prompt 4."""

from __future__ import annotations

from collections import Counter
from typing import Any

import pandas as pd

from .data_understanding import profile_dataframe


def _norm(value: Any) -> str:
    return " ".join(str(value).strip().casefold().split())


def _json_rows(frame: pd.DataFrame) -> list[dict[str, Any]]:
    """Convert pandas scalars to JSON-safe values without changing the source."""
    rows: list[dict[str, Any]] = []
    for row in frame.to_dict(orient="records"):
        clean_row: dict[str, Any] = {}
        for column, value in row.items():
            if value is pd.NA or (isinstance(value, float) and pd.isna(value)):
                clean_row[str(column)] = None
            elif hasattr(value, "item"):
                clean_row[str(column)] = value.item()
            else:
                clean_row[str(column)] = value
        rows.append(clean_row)
    return rows


def _parse_dates(series: pd.Series) -> pd.Series:
    try:
        return pd.to_datetime(series, errors="coerce", format="mixed")
    except (TypeError, ValueError):
        return pd.to_datetime(series, errors="coerce")


def _score(name: str, frame: pd.DataFrame, profile: dict[str, Any]) -> tuple[int, str | None]:
    tokens = set(name.casefold().replace("-", "_").split("_"))
    event_words = {"order", "orders", "transaction", "transactions", "sales", "sale", "fact", "events", "event", "invoice", "invoices"}
    key_candidates = profile.get("business_key_candidates") or []
    event_key = next((key for key in key_candidates if any(word in key.casefold() for word in event_words)), None)
    if event_key is None and key_candidates:
        event_key = max(key_candidates, key=lambda key: frame[key].notna().sum() / max(len(frame), 1))
    measures = [entry for entry in profile.get("schema", []) if entry.get("role") == "numeric_measure"]
    dates = [entry for entry in profile.get("schema", []) if entry.get("role") == "datetime"]
    score = 12 if tokens & event_words else 0
    score += 5 if event_key else 0
    score += min(len(measures), 4) + (3 if dates else 0)
    return score, event_key


def _key_profile(frame: pd.DataFrame, key: str | None) -> dict[str, Any]:
    if not key or key not in frame:
        return {"column": key, "unique": 0, "null": int(len(frame)), "duplicate_groups": 0, "physically_unique": False}
    values = frame[key]
    non_null = values.dropna()
    return {
        "column": key,
        "unique": int(non_null.nunique()),
        "null": int(values.isna().sum()),
        "duplicate_groups": int(non_null.value_counts().gt(1).sum()),
        "physically_unique": bool(values.notna().all() and non_null.nunique() == len(frame)),
    }


def _measure_columns(profile: dict[str, Any], frame: pd.DataFrame, excluded: set[str]) -> list[str]:
    return [entry["column"] for entry in profile.get("schema", []) if entry.get("role") == "numeric_measure" and entry["column"] not in excluded and pd.api.types.is_numeric_dtype(frame[entry["column"]])]


def _relationship(frame: pd.DataFrame, column: str, parent: pd.DataFrame, parent_key: str, target: str) -> dict[str, Any]:
    values = frame[column]
    non_null = values.dropna().map(_norm)
    parent_values = set(parent[parent_key].dropna().map(_norm))
    valid = non_null.isin(parent_values)
    return {
        "source_table": "fact_orders",
        "source_column": column,
        "target_table": target,
        "target_column": parent_key,
        "cardinality": "many -> one" if parent[parent_key].dropna().nunique() == len(parent[parent_key].dropna()) else "not validated",
        "parent_key_unique": bool(parent[parent_key].dropna().nunique() == len(parent[parent_key].dropna())),
        "total_fact_rows": int(len(frame)),
        "null_fk_rows": int(values.isna().sum()),
        "non_null_fk_rows": int(len(non_null)),
        "orphan_fk_rows": int((~valid).sum()),
        "non_null_referential_coverage": round(float(valid.mean()), 6) if len(non_null) else 0.0,
        "status": "VALID" if not values.isna().any() and not (~valid).any() else "MISSING_FK" if values.isna().any() and not (~valid).any() else "ORPHAN_FK" if (~valid).any() else "VALID",
    }


def clean_order_fact(tables: dict[str, pd.DataFrame], source_hashes: dict[str, str] | None = None) -> dict[str, Any]:
    if not tables:
        raise ValueError("At least one dataset is required.")
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    ranked = sorted(((_score(name, tables[name], profiles[name]), name) for name in tables), reverse=True)
    score, selected = ranked[0]
    if score[0] <= 0 or not score[1]:
        return {"status": "BLOCKED", "error": "No fact/event dataset with a reliable event key was identified."}

    source = tables[selected]
    profile = profiles[selected]
    event_key = score[1]
    date_entry = next((entry for entry in profile.get("schema", []) if entry.get("logical_type") == "datetime"), None)
    date_column = date_entry["column"] if date_entry else next((column for column in source.columns if any(word in column.casefold() for word in ("date", "time", "timestamp"))), None)
    quantity_column = next((column for column in source.columns if any(word in column.casefold() for word in ("quantity", "qty", "units", "count"))), None)
    measures = _measure_columns(profile, source, {event_key})
    raw = source.copy(deep=True)
    exact_mask = raw.duplicated(keep="first")
    exact_groups = raw[raw.duplicated(keep=False)].groupby(list(raw.columns), dropna=False, sort=False).size()
    cleaned = raw.loc[~exact_mask].copy().reset_index(drop=True)

    conflicting_groups = []
    if event_key in cleaned:
        non_key = [column for column in cleaned.columns if column != event_key]
        for value, group in cleaned.groupby(event_key, dropna=False, sort=False):
            if pd.isna(value) or len(group) < 2:
                continue
            if group[non_key].drop_duplicates().shape[0] > 1:
                conflicting_groups.append({"event_key": str(value), "rows": int(len(group)), "classification": "CONFLICTING EVENT KEY", "outcome": "REQUIRES REVIEW"})

    parsed = _parse_dates(cleaned[date_column]) if date_column else pd.Series(pd.NaT, index=cleaned.index)
    date_status = pd.Series("NULL", index=cleaned.index, dtype="object")
    if date_column:
        date_status.loc[cleaned[date_column].notna() & parsed.notna()] = "VALID"
        date_status.loc[cleaned[date_column].notna() & parsed.isna()] = "INVALID"
        cleaned[f"{date_column}_parsed"] = parsed.dt.strftime("%Y-%m-%d %H:%M:%S")
        cleaned[f"{date_column}_status"] = date_status

    numeric_quantity = pd.to_numeric(cleaned[quantity_column], errors="coerce") if quantity_column else pd.Series(pd.NA, index=cleaned.index, dtype="Float64")
    cleaned["is_return"] = numeric_quantity.map(lambda value: True if pd.notna(value) and value < 0 else False if pd.notna(value) else pd.NA)

    duplicate_measure_impact = {}
    for measure in measures:
        raw_values = pd.to_numeric(raw[measure], errors="coerce")
        clean_values = pd.to_numeric(cleaned[measure], errors="coerce")
        duplicate_measure_impact[measure] = {"raw_total": float(raw_values.sum()), "removed_duplicate_contribution": float(raw_values.sum() - clean_values.sum()), "clean_total": float(clean_values.sum()), "reconciles": bool(abs(float(raw_values.sum() - clean_values.sum()) - float(raw.loc[exact_mask, measure].sum())) <= 1e-8)}

    relationships = []
    target_specs: dict[str, tuple[pd.DataFrame, str, str]] = {}
    for name, frame in tables.items():
        if name == selected:
            continue
        other_profile = profiles[name]
        other_key = (other_profile.get("primary_key_candidates") or other_profile.get("business_key_candidates") or [None])[0]
        if not other_key or other_key not in frame:
            continue
        target = "dim_customer" if "customer" in name.casefold() else "dim_product" if "product" in name.casefold() or "item" in name.casefold() else name
        parent = frame.copy(deep=True)
        if target == "dim_customer":
            try:
                from .customer_cleaning import clean_customer_dimension
                result = clean_customer_dimension({name: frame})
                if result.get("cleaned_table", {}).get("rows") is not None:
                    parent = pd.DataFrame(result["cleaned_table"]["rows"], columns=result["cleaned_table"]["columns"])
            except Exception:
                pass
        elif target == "dim_product":
            try:
                from .product_cleaning import clean_product_dimension
                result = clean_product_dimension({name: frame})
                parent = pd.DataFrame(result["cleaned_table"]["rows"], columns=result["cleaned_table"]["columns"])
            except Exception:
                pass
        for column in cleaned.columns:
            if column == event_key or column not in source.columns or column != other_key:
                continue
            target_specs[column] = (parent, other_key, target)
    for column, (parent, parent_key, target) in sorted(target_specs.items()):
        relationships.append(_relationship(cleaned, column, parent, parent_key, target))

    formula_checks = []
    sales = next((column for column in source.columns if any(word in column.casefold() for word in ("sales", "revenue"))), None)
    cost = next((column for column in source.columns if "cost" in column.casefold()), None)
    profit = next((column for column in source.columns if "profit" in column.casefold()), None)
    if sales and cost and profit:
        expected = pd.to_numeric(cleaned[sales], errors="coerce") - pd.to_numeric(cleaned[cost], errors="coerce")
        actual = pd.to_numeric(cleaned[profit], errors="coerce")
        formula_checks.append({"formula": f"{sales} - {cost} = {profit}", "inconsistent_rows": int((expected - actual).abs().gt(1e-8).sum()), "status": "REVIEW" if (expected - actual).abs().gt(1e-8).any() else "CONSISTENT"})

    raw_rows = int(len(raw))
    removed = int(exact_mask.sum())
    invalid_date_rows = int((date_status == "INVALID").sum())
    null_fk = {column: int(cleaned[column].isna().sum()) for column in source.columns if column in target_specs}
    result = {
        "success": True,
        "status": "BLOCKED" if len(cleaned) != raw_rows - removed else "READY" if not conflicting_groups and not invalid_date_rows and not any(value for value in null_fk.values()) else "READY WITH REVIEW ITEMS",
        "source_dataset": selected,
        "fact_name": "fact_orders" if "order" in selected.casefold() else f"fact_{selected}",
        "raw_source_hashes": source_hashes or {},
        "read_only": True,
        "grain": {"intended": f"One row per {event_key} event/transaction as inferred from the business key candidate.", "cleaned": f"One row per observed {event_key} event after exact duplicate removal; repeated foreign keys remain valid fact rows."},
        "event_key": _key_profile(raw, event_key),
        "summary": {"raw_rows": raw_rows, "exact_duplicate_rows": int(exact_mask.sum()), "exact_duplicate_groups": int(len(exact_groups)), "exact_duplicates_removed": removed, "conflicting_event_key_groups": len(conflicting_groups), "clean_rows": int(len(cleaned)), "valid_date_rows": int((date_status == "VALID").sum()), "invalid_date_rows": invalid_date_rows, "null_date_rows": int((date_status == "NULL").sum()), "null_fk_rows": null_fk, "orphan_fk_rows": {item["source_column"]: item["orphan_fk_rows"] for item in relationships}, "negative_quantity_rows": int((numeric_quantity < 0).sum()), "is_return_true": int((cleaned["is_return"] == True).sum()), "is_return_false": int((cleaned["is_return"] == False).sum()), "is_return_unknown": int(cleaned["is_return"].isna().sum())},
        "duplicate_audit": {"affected_event_keys": sorted({str(value) for value in raw.loc[exact_mask, event_key].dropna().tolist()}), "affected_measures": duplicate_measure_impact, "exact_duplicate_representative": "First occurrence in stable input order retained."},
        "conflicting_event_keys": conflicting_groups,
        "date_handling": {"column": date_column, "invalid_policy": "Rows preserved; parsed representation is null and status is INVALID.", "status_counts": {"VALID": int((date_status == "VALID").sum()), "NULL": int((date_status == "NULL").sum()), "INVALID": invalid_date_rows}},
        "relationships": relationships,
        "formula_checks": formula_checks,
        "audit_trail": [
            {"rule": "Remove confirmed exact duplicate fact rows", "affected_rows": removed, "before_state": raw_rows, "after_state": int(len(cleaned)), "reason": "Complete row equality makes only the redundant copy removable.", "outcome": "One deterministic representative retained."},
            {"rule": "Parse the primary event date", "affected_rows": int((date_status == "VALID").sum()), "before_state": date_column, "after_state": "valid parsed date representation", "reason": "Semantic date inference from the fact schema.", "outcome": "Valid dates retained for Prompt 5."},
            {"rule": "Mark malformed event dates unresolved", "affected_rows": invalid_date_rows, "before_state": "non-null raw date", "after_state": "INVALID / parsed null", "reason": "No dates are invented.", "outcome": "Rows preserved for review."},
            {"rule": "Classify foreign-key quality", "affected_rows": sum(null_fk.values()), "before_state": "raw FK values", "after_state": "VALID, MISSING_FK, or ORPHAN_FK metadata", "reason": "Relationships are evaluated against dimension keys.", "outcome": "No IDs invented and no FK rows dropped."},
            {"rule": "Create is_return from explicit business rule", "affected_rows": int((numeric_quantity < 0).sum()), "before_state": quantity_column, "after_state": "is_return=true", "reason": "The workflow explicitly defines negative quantity as a return.", "outcome": "Null/non-numeric quantities remain unknown."},
        ],
        "measure_reconciliation": duplicate_measure_impact,
        "fact_schema": {"columns": [str(column) for column in cleaned.columns], "measures": measures, "foreign_keys": [item["source_column"] for item in relationships], "derived_fields": ["is_return"] + ([f"{date_column}_parsed", f"{date_column}_status"] if date_column else [])},
        "cleaned_table": {"name": "fact_orders" if "order" in selected.casefold() else f"fact_{selected}", "columns": [str(column) for column in cleaned.columns], "rows": _json_rows(cleaned)},
        "model_readiness": {"status": "READY WITH REVIEW ITEMS" if invalid_date_rows or null_fk or conflicting_groups else "READY", "review_items": ["Malformed dates remain unresolved." for _ in range(1) if invalid_date_rows] + ["Missing foreign keys remain in the fact." for _ in range(1) if any(null_fk.values())] + ["Conflicting event-key groups require review." for _ in range(1) if conflicting_groups], "next_step": "Build dim_date from valid parsed fact dates, then confirm policies for unresolved dates and missing dimension members."},
    }
    return result
