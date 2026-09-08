"""Generic, read-only customer/entity dimension cleaning."""

from __future__ import annotations

from typing import Any

import pandas as pd

from .data_understanding import profile_dataframe


def _customer_score(name: str, profile: dict[str, Any]) -> tuple[int, str | None]:
    key = (profile.get("business_key_candidates") or [None])[0]
    tokens = set(name.casefold().replace("-", "_").split("_"))
    score = 0
    if tokens & {"customer", "customers", "client", "clients", "member", "members"}:
        score += 10
    if key:
        score += 4
    if profile.get("primary_key_candidates"):
        score += 2
    if profile.get("schema"):
        score += sum(entry.get("role") == "categorical" for entry in profile["schema"])
    return score, key


def _clean_one(name: str, frame: pd.DataFrame, profile: dict[str, Any]) -> tuple[pd.DataFrame, dict[str, Any]]:
    key = (profile.get("business_key_candidates") or [None])[0]
    if not key or key not in frame.columns:
        return frame.iloc[0:0].copy(), {
            "status": "BLOCKED",
            "business_key": key,
            "reason": "No reliable business key was inferred.",
            "raw_rows": int(len(frame)),
            "clean_rows": 0,
            "null_key_rows": int(frame[key].isna().sum()) if key in frame else int(len(frame)),
            "exact_duplicates_removed": 0,
            "identical_duplicate_key_groups_resolved": 0,
            "conflicting_duplicate_key_groups": 0,
            "automatically_resolved": 0,
            "requires_review": 0,
            "audit_trail": [],
        }
    non_null = frame[frame[key].notna()].copy()
    null_key_rows = int(frame[key].isna().sum())
    exact_extra = int(frame.duplicated(keep="first").sum())
    clean_groups: list[pd.DataFrame] = []
    identical_groups = conflicting_groups = 0
    review_examples: list[dict[str, Any]] = []
    normalized_key = non_null[key].astype(str).map(lambda value: " ".join(value.casefold().split()))
    for value, group in non_null.groupby(normalized_key, sort=False, dropna=True):
        non_key = [column for column in frame.columns if column != key]
        if group[non_key].drop_duplicates().shape[0] == 1:
            clean_groups.append(group.iloc[[0]])
            if len(group) > 1:
                identical_groups += 1
        else:
            conflicting_groups += 1
            if len(review_examples) < 8:
                review_examples.append({"key": str(value), "rows": int(len(group)), "classification": "CONFLICTING KEY DUPLICATE"})
    cleaned = pd.concat(clean_groups, ignore_index=True) if clean_groups else frame.iloc[0:0].copy()
    audit = [
        {"rule": "Collapse exact duplicate rows", "affected_rows": exact_extra, "affected_key_groups": 0, "rationale": "Complete row equality makes the extra copy redundant.", "outcome": "Redundant copies removed from cleaned result."},
        {"rule": "Safe collapse of identical key duplicates", "affected_rows": max(0, int(len(non_null) - len(cleaned)) - exact_extra), "affected_key_groups": identical_groups, "rationale": "Same business key and identical non-key attributes.", "outcome": "One deterministic representative retained per key."},
        {"rule": "Exclude conflicting key duplicates", "affected_rows": int(sum(len(group) for _, group in non_null.groupby(key, sort=False, dropna=True) if group[[column for column in frame.columns if column != key]].drop_duplicates().shape[0] > 1)), "affected_key_groups": conflicting_groups, "rationale": "Business intent cannot be proven without selecting an arbitrary record.", "outcome": "Requires review; no conflicting record was silently chosen."},
        {"rule": "Exclude null business keys", "affected_rows": null_key_rows, "affected_key_groups": 0, "rationale": "IDs are not invented during diagnostic cleaning.", "outcome": "Excluded from dimension and reported for review."},
    ]
    final_duplicates = int(cleaned.duplicated(subset=[key], keep=False).sum())
    status = "READY" if not conflicting_groups and not null_key_rows and final_duplicates == 0 else "REQUIRES REVIEW"
    return cleaned, {
        "status": status,
        "business_key": key,
        "raw_rows": int(len(frame)),
        "clean_rows": int(len(cleaned)),
        "null_key_rows": null_key_rows,
        "exact_duplicate_rows_removed": exact_extra,
        "identical_duplicate_key_groups_resolved": identical_groups,
        "conflicting_duplicate_key_groups": conflicting_groups,
        "automatically_resolved": identical_groups,
        "requires_review": conflicting_groups + (1 if null_key_rows else 0),
        "final_key_uniqueness_percent": 100.0 if len(cleaned) == 0 or final_duplicates == 0 else 0.0,
        "final_duplicate_key_groups": int(cleaned[key].duplicated(keep=False).sum() if key in cleaned else 0),
        "review_examples": review_examples,
        "audit_trail": audit,
    }


def clean_customer_dimension(tables: dict[str, pd.DataFrame]) -> dict[str, Any]:
    if not tables:
        raise ValueError("At least one dataset is required.")
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    candidates = sorted(((_customer_score(name, profiles[name]), name) for name in tables), reverse=True)
    score, selected = candidates[0]
    if score[0] <= 0:
        return {"status": "BLOCKED", "error": "No customer/entity-like dataset was confidently identified."}
    cleaned, summary = _clean_one(selected, tables[selected], profiles[selected])
    key = summary.get("business_key")
    relationships = []
    if key:
        parent_values = set(cleaned[key].astype(str).map(lambda value: " ".join(value.casefold().split())))
        for name, frame in tables.items():
            if name == selected:
                continue
            for column in frame.columns:
                if str(column).casefold() != str(key).casefold():
                    continue
                values = frame[column]
                non_null = values.dropna().astype(str).str.strip()
                normalized_non_null = non_null.map(lambda value: " ".join(value.casefold().split()))
                orphan = int((~normalized_non_null.isin(parent_values)).sum())
                relationships.append({"source_table": name, "source_column": column, "target_table": "dim_customer", "target_column": key, "cardinality": "many_to_one" if summary["final_duplicate_key_groups"] == 0 else "not_validated", "null_fk_count": int(values.isna().sum()), "orphan_fk_rows": orphan, "non_null_referential_coverage": round(float(normalized_non_null.isin(parent_values).mean()), 4) if len(non_null) else 0.0, "parent_key_unique": summary["final_duplicate_key_groups"] == 0})
    return {
        "status": summary["status"],
        "source_dataset": selected,
        "dimension_name": "dim_customer",
        "summary": summary,
        "dimension_schema": {"key": key, "attributes": [column for column in cleaned.columns if column != key]},
        "cleaned_table": {"name": "dim_customer", "columns": [str(column) for column in cleaned.columns], "rows": cleaned.where(pd.notna(cleaned), None).to_dict(orient="records")},
        "relationships": relationships,
        "read_only": True,
    }
