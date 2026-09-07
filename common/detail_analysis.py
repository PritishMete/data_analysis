"""Cross-dataset profiling for detail analysis.

The normal scan intentionally describes one table. This module is the
multi-table path: it compares key candidates and value overlap only when the
caller supplies the datasets together, so fact/dimension claims are grounded
in the same analysis request.
"""

from __future__ import annotations

from collections import Counter
import io
from pathlib import Path
from typing import Any

import pandas as pd

from .data_understanding import profile_dataframe


def _safe_name(name: str) -> str:
    return Path(name).stem or "Dataset"


def load_dataset_tables(raw_bytes: bytes, filename: str) -> dict[str, pd.DataFrame]:
    """Load one uploaded file into one or more named tables."""
    lower = filename.casefold()
    if lower.endswith((".xlsx", ".xlsm", ".xls")):
        tables = pd.read_excel(io.BytesIO(raw_bytes), sheet_name=None)
        return {str(name): frame for name, frame in tables.items() if not frame.empty}
    if lower.endswith((".tsv", ".tab")):
        return {_safe_name(filename): pd.read_csv(io.BytesIO(raw_bytes), sep="\t")}
    if lower.endswith(".csv"):
        return {_safe_name(filename): pd.read_csv(io.BytesIO(raw_bytes))}
    if lower.endswith(".json"):
        return {_safe_name(filename): pd.DataFrame(pd.read_json(io.BytesIO(raw_bytes)))}
    raise ValueError(f"Unsupported detail-analysis file: {filename}")


def _overlap(left: pd.Series, right: pd.Series) -> float:
    left_values = set(left.dropna().astype(str).str.strip())
    right_values = set(right.dropna().astype(str).str.strip())
    if not left_values or not right_values:
        return 0.0
    return len(left_values & right_values) / len(left_values)


def analyze_dataset_collection(tables: dict[str, pd.DataFrame]) -> dict[str, Any]:
    """Profile all supplied tables and infer cross-table model candidates."""
    if not tables:
        raise ValueError("At least one non-empty dataset is required.")

    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    fact_scores: Counter[str] = Counter()
    dimension_scores: Counter[str] = Counter()
    for name, profile in profiles.items():
        schema = profile["schema"]
        measures = [c for c in schema if c["role"] == "numeric_measure"]
        keys = profile["primary_key_candidates"]
        foreign_keys = profile["foreign_key_candidates"]
        if measures:
            fact_scores[name] += 3
        if foreign_keys:
            fact_scores[name] += 2
        if keys and not measures:
            dimension_scores[name] += 3
        if keys and len(schema) <= 8:
            dimension_scores[name] += 1

    relationships: list[dict[str, Any]] = []
    for source_name, source_profile in profiles.items():
        source_frame = tables[source_name]
        source_columns = source_profile["foreign_key_candidates"]
        for target_name, target_profile in profiles.items():
            if source_name == target_name:
                continue
            target_frame = tables[target_name]
            target_keys = target_profile["primary_key_candidates"]
            for source_column in source_columns:
                if source_column not in source_frame.columns:
                    continue
                for target_column in target_keys:
                    if target_column not in target_frame.columns:
                        continue
                    confidence = _overlap(source_frame[source_column], target_frame[target_column])
                    same_name = source_column.casefold() == target_column.casefold()
                    if confidence >= 0.8 and (same_name or confidence >= 0.95):
                        relationships.append({
                            "source_table": source_name,
                            "source_column": source_column,
                            "target_table": target_name,
                            "target_column": target_column,
                            "confidence": round(confidence, 4),
                        })

    fact_tables = [name for name, _ in fact_scores.most_common() if fact_scores[name] > 0]
    dimension_tables = [name for name, _ in dimension_scores.most_common() if dimension_scores[name] > 0 and name not in fact_tables]
    if not fact_tables and len(tables) == 1:
        fact_tables = [next(iter(tables))]

    return {
        "analysis_mode": "multi_dataset_detail",
        "dataset_count": len(tables),
        "datasets": [
            {
                "name": name,
                "rows": int(len(frame)),
                "columns": int(len(frame.columns)),
                "profile": profiles[name],
            }
            for name, frame in tables.items()
        ],
        "relationships": relationships,
        "model_recommendation": {
            "fact_tables": fact_tables,
            "dimension_tables": dimension_tables,
            "star_schema": {
                "fact_tables": fact_tables,
                "dimension_tables": dimension_tables,
                "relationships": relationships,
            },
            "status": "candidate_model" if not relationships else "relationship_backed_candidate_model",
            "note": "Confirm business grain and relationship direction before production modeling.",
        },
        "limitations": [
            "Relationships are proposed only from supplied tables in this request.",
            "A browser folder picker sends selected files, not the user's local path.",
            "Large sources should use the local backend or Power BI connector path; raw rows are not returned in this response.",
        ],
    }
