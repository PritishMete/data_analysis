"""Generic, read-only product/item dimension cleaning."""

from __future__ import annotations

from collections import Counter
from typing import Any

import pandas as pd

from .data_understanding import profile_dataframe


CONFIDENCE_THRESHOLD = 0.80


def _norm(value: Any) -> str:
    return " ".join(str(value).strip().casefold().split())


def _score(name: str, profile: dict[str, Any]) -> tuple[int, str | None]:
    tokens = set(name.casefold().replace("-", "_").split("_"))
    key = (profile.get("business_key_candidates") or [None])[0]
    score = 10 if tokens & {"product", "products", "item", "items", "sku", "skus"} else 0
    return score + (4 if key else 0) + (2 if profile.get("primary_key_candidates") else 0), key


def _canonical_map(series: pd.Series) -> tuple[dict[str, str], list[dict[str, Any]]]:
    groups: dict[str, Counter[str]] = {}
    for raw in series.dropna().astype(str):
        if raw.strip():
            groups.setdefault(_norm(raw), Counter())[raw.strip()] += 1
    mapping: dict[str, str] = {}
    audit: list[dict[str, Any]] = []
    for normalized, counts in groups.items():
        canonical = sorted(counts.items(), key=lambda item: (-item[1], item[0]))[0][0]
        mapping[normalized] = canonical
        variants = [value for value in counts if value != canonical]
        if variants:
            audit.append({"raw_variants": variants + [canonical], "canonical_value": canonical, "affected_rows": int(sum(counts[value] for value in variants)), "reason": "Equivalent after case/whitespace normalization.", "resolution_type": "REPRESENTATIONAL ONLY"})
    return mapping, audit


def clean_product_dimension(tables: dict[str, pd.DataFrame]) -> dict[str, Any]:
    if not tables:
        raise ValueError("At least one dataset is required.")
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    ranked = sorted(((_score(name, profiles[name]), name) for name in tables), reverse=True)
    score, selected = ranked[0]
    if score[0] <= 0:
        return {"status": "BLOCKED", "error": "No product/item-like dataset was confidently identified."}
    source = tables[selected]
    profile = profiles[selected]
    key = score[1]
    if not key:
        return {"status": "BLOCKED", "source_dataset": selected, "error": "No reliable product business key was inferred."}
    clean = source.copy(deep=True)
    categorical = [entry["column"] for entry in profile.get("schema", []) if entry.get("role") == "categorical"]
    normalization_audit: list[dict[str, Any]] = []
    for column in categorical:
        mapping, audit = _canonical_map(source[column])
        clean[column] = source[column].map(lambda value: mapping.get(_norm(value), value) if pd.notna(value) else value)
        for item in audit:
            item["field"] = column
            normalization_audit.append(item)
    category = next((column for column in categorical if column.casefold() in {"category", "product_category"}), None)
    subcategory = next((column for column in categorical if column.casefold() in {"sub_category", "subcategory", "product_subcategory"}), None)
    mappings: list[dict[str, Any]] = []
    mismatch_rows = 0
    if category and subcategory:
        pairs = pd.DataFrame({_category: source[_category].map(_norm) for _category in [category, subcategory]})
        for sub, group in pairs.groupby(subcategory, sort=True):
            counts = group[category].value_counts()
            if counts.empty:
                continue
            dominant = str(counts.index[0]); support = float(counts.iloc[0] / counts.sum())
            alternatives = {str(index): int(value) for index, value in counts.iloc[1:].items()}
            mismatch = int((group[category] != dominant).sum())
            mismatch_rows += mismatch
            if len(counts) > 1:
                mappings.append({"sub_category": str(sub), "observed_categories": {str(index): int(value) for index, value in counts.items()}, "dominant_category": dominant, "support_percent": round(support * 100, 4), "alternative_categories": alternatives, "mismatch_rows": mismatch, "action": "AUTO-RESOLVE" if support >= CONFIDENCE_THRESHOLD and len(counts) == 1 else "REVIEW", "status": "REPRESENTATIONAL ONLY" if len(counts) == 1 else "BUSINESS MAPPING CONFLICT" if support >= CONFIDENCE_THRESHOLD else "INSUFFICIENT EVIDENCE"})
    final_duplicates = int(clean[key].duplicated(keep=False).sum())
    status = "READY" if final_duplicates == 0 and mismatch_rows == 0 else "READY WITH REVIEW ITEMS" if final_duplicates == 0 else "BLOCKED"
    relationships = []
    parent_values = set(clean[key].dropna().astype(str).map(_norm))
    for name, frame in tables.items():
        if name == selected or key not in frame.columns:
            continue
        values = frame[key]
        non_null = values.dropna().map(_norm)
        relationships.append({"source_table": name, "source_column": key, "target_table": "dim_product", "target_column": key, "cardinality": "many_to_one" if final_duplicates == 0 else "not_validated", "parent_key_unique": final_duplicates == 0, "null_fk_count": int(values.isna().sum()), "orphan_fk_rows": int((~non_null.isin(parent_values)).sum()), "non_null_referential_coverage": round(float(non_null.isin(parent_values).mean()), 4) if len(non_null) else 0.0})
    return {"success": True, "status": status, "source_dataset": selected, "dimension_name": "dim_product", "summary": {"raw_rows": int(len(source)), "clean_rows": int(len(clean)), "business_key": key, "raw_unique_product_keys": int(source[key].dropna().nunique()), "clean_unique_product_keys": int(clean[key].dropna().nunique()), "raw_category_distinct": int(source[category].nunique(dropna=True)) if category else 0, "clean_category_distinct": int(clean[category].nunique(dropna=True)) if category else 0, "raw_subcategory_distinct": int(source[subcategory].nunique(dropna=True)) if subcategory else 0, "clean_subcategory_distinct": int(clean[subcategory].nunique(dropna=True)) if subcategory else 0, "representation_issues_resolved": len(normalization_audit), "category_subcategory_mismatch_rows": mismatch_rows, "unresolved_business_conflicts": sum(item["status"] != "REPRESENTATIONAL ONLY" for item in mappings), "final_key_uniqueness_percent": 100.0 if final_duplicates == 0 else 0.0, "final_duplicate_key_groups": int(clean[key].value_counts().gt(1).sum()), "status": status}, "normalization_audit": normalization_audit[:40], "mapping_issues": mappings[:40], "relationships": relationships, "dimension_schema": {"key": key, "attributes": [column for column in clean.columns if column != key]}, "cleaned_table": {"name": "dim_product", "columns": [str(column) for column in clean.columns], "rows": clean.where(pd.notna(clean), None).to_dict(orient="records")}, "read_only": True}
