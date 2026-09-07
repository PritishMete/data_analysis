"""Cross-dataset profiling for detail analysis.

The normal scan intentionally describes one table. This module is the
multi-table path: it compares key candidates and value overlap only when the
caller supplies the datasets together, so fact/dimension claims are grounded
in the same analysis request.
"""

from __future__ import annotations

from collections import Counter
import io
import re
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


def _name_tokens(name: str) -> set[str]:
    return {token for token in re.split(r"[^a-z0-9]+", name.casefold()) if token}


def _table_hint(name: str) -> str:
    tokens = _name_tokens(name)
    if tokens & {"order", "orders", "sales", "sale", "transaction", "transactions", "fact", "facts"}:
        return "fact"
    if tokens & {"customer", "customers", "product", "products", "region", "regions", "dim", "dimension", "dimensions"}:
        return "dimension"
    return "unknown"


def _is_relationship_column(column: str) -> bool:
    tokens = _name_tokens(column)
    return bool(tokens & {"id", "key", "code"}) or column.casefold().endswith(("_id", "_key", "_code"))


def _semantic_column_name(column: str) -> str:
    """Normalize key suffixes while retaining the entity name."""
    tokens = _name_tokens(column)
    return "_".join(sorted(tokens - {"id", "key", "code"}))


def _model_scores(name: str, profile: dict[str, Any]) -> tuple[float, float]:
    """Score table roles without treating every numeric attribute as a fact."""
    schema = profile["schema"]
    hint = _table_hint(name)
    id_columns = [entry for entry in schema if entry["role"] == "identifier"]
    measures = [entry for entry in schema if entry["role"] == "numeric_measure"]
    candidate_fks = profile["foreign_key_candidates"]
    repeated_rows = profile["dataset_overview"]["rows"] > max(
        (entry["unique"] for entry in schema), default=0
    )

    fact = 0.0
    dimension = 0.0
    if hint == "fact":
        fact += 8
    elif hint == "dimension":
        dimension += 8
    if candidate_fks:
        fact += 4
    if repeated_rows:
        fact += 2
    # Measures support a fact hypothesis only when the table otherwise looks
    # like an event table. Age, cost, and selling_price are normal attributes
    # in entity tables and must not override the table-level hint.
    if measures and hint not in {"dimension"}:
        fact += min(3, len(measures))
    if id_columns and hint == "dimension":
        dimension += 3
    if id_columns and not candidate_fks and not repeated_rows:
        dimension += 2
    return fact, dimension


def analyze_dataset_collection(tables: dict[str, pd.DataFrame]) -> dict[str, Any]:
    """Profile all supplied tables and infer cross-table model candidates."""
    if not tables:
        raise ValueError("At least one non-empty dataset is required.")

    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    fact_scores: Counter[str] = Counter()
    dimension_scores: Counter[str] = Counter()
    for name, profile in profiles.items():
        fact, dimension = _model_scores(name, profile)
        fact_scores[name] += fact
        dimension_scores[name] += dimension

    relationships: list[dict[str, Any]] = []
    for source_name, source_profile in profiles.items():
        source_frame = tables[source_name]
        source_columns = list(source_profile["foreign_key_candidates"])
        # Small samples can make a foreign key look unique. Keep all
        # identifier-like columns eligible on the source side and let semantic
        # name matching plus overlap decide whether a join is credible.
        source_columns.extend(
            entry["column"]
            for entry in source_profile["schema"]
            if _is_relationship_column(entry["column"])
            and entry["column"] not in source_columns
        )
        for target_name, target_profile in profiles.items():
            if source_name == target_name:
                continue
            target_frame = tables[target_name]
            target_keys = [] if _table_hint(target_name) == "fact" else list(target_profile["primary_key_candidates"])
            # A dimension can contain duplicate records and still be the
            # intended relationship target. Keep the quality warning, but do
            # not lose an obvious *_id relationship because of it.
            if _table_hint(target_name) == "dimension":
                target_keys.extend(
                    entry["column"]
                    for entry in target_profile["schema"]
                    if _is_relationship_column(entry["column"])
                    and entry["column"] not in target_keys
                )
            for source_column in source_columns:
                if source_column not in source_frame.columns:
                    continue
                for target_column in target_keys:
                    if target_column not in target_frame.columns:
                        continue
                    confidence = _overlap(source_frame[source_column], target_frame[target_column])
                    same_name = _semantic_column_name(source_column) == _semantic_column_name(target_column)
                    if confidence >= 0.8 and same_name:
                        if any(
                            item["source_table"] == source_name
                            and item["source_column"] == source_column
                            and item["target_table"] == target_name
                            and item["target_column"] == target_column
                            for item in relationships
                        ):
                            continue
                        relationships.append({
                            "source_table": source_name,
                            "source_column": source_column,
                            "target_table": target_name,
                            "target_column": target_column,
                            "confidence": round(confidence, 4),
                        })

    ranked_facts = [name for name, _ in fact_scores.most_common() if fact_scores[name] > 0]
    ranked_dimensions = [name for name, _ in dimension_scores.most_common() if dimension_scores[name] > 0]
    # Prefer the strongest fact candidate. Multiple fact tables are retained
    # only when they are both strongly transaction-like.
    fact_tables = [name for name in ranked_facts if fact_scores[name] >= 8]
    if not fact_tables and ranked_facts:
        fact_tables = [ranked_facts[0]]
    dimension_tables = [name for name in ranked_dimensions if name not in fact_tables]
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
            "note": "Numeric attributes do not make an entity table a fact table; confirm business grain before production modeling.",
        },
        "limitations": [
            "Relationships are proposed only from supplied tables in this request.",
            "A browser folder picker sends selected files, not the user's local path.",
            "Large sources should use the local backend or Power BI connector path; raw rows are not returned in this response.",
        ],
    }
