"""Gemini schema interpretation for multi-dataset detail analysis.

Only structural metadata is sent to the agent. Deterministic profiling remains
the source of truth for observed counts and validates every model reference.
"""

from __future__ import annotations

import json
import os
from typing import Any

from ai_analyst import MODEL, _json_safe, _run_single_agent, LlmAgent
from privacy_context import strict_enabled


def _metadata_payload(result: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    aliases: dict[str, str] = {}
    tables: list[dict[str, Any]] = []
    for index, dataset in enumerate(result.get("datasets", []), start=1):
        table_alias = f"T{index}"
        aliases[table_alias] = dataset["name"]
        profile = dataset["profile"]
        columns = []
        for col_index, entry in enumerate(profile.get("schema", []), start=1):
            column_alias = f"C{index}_{col_index}"
            aliases[column_alias] = entry["column"]
            columns.append({
                "column_id": column_alias,
                "dtype": entry.get("dtype"),
                "role": entry.get("role"),
                "non_null": entry.get("non_null"),
                "missing": entry.get("missing"),
                "unique": entry.get("unique"),
                "key_candidate": entry.get("key_candidate", False),
            })
        tables.append({
            "table_id": table_alias,
            "rows": dataset["rows"],
            "columns": dataset["columns"],
            "schema": columns,
            "primary_key_candidates": [
                next((key for key, value in aliases.items() if value == name), name)
                for name in profile.get("primary_key_candidates", [])
            ],
            "foreign_key_candidates": [
                next((key for key, value in aliases.items() if value == name), name)
                for name in profile.get("foreign_key_candidates", [])
            ],
            "quality_counts": {
                "suspicious_value_count": len(profile.get("invalid_or_suspicious_values", [])),
                "categorical_inconsistency_count": len(profile.get("categorical_inconsistencies", [])),
            },
        })
    relationships = []
    for relationship in result.get("relationships", []):
        relationships.append({
            "source_table": next((key for key, value in aliases.items() if value == relationship["source_table"]), relationship["source_table"]),
            "source_column": next((key for key, value in aliases.items() if value == relationship["source_column"]), relationship["source_column"]),
            "target_table": next((key for key, value in aliases.items() if value == relationship["target_table"]), relationship["target_table"]),
            "target_column": next((key for key, value in aliases.items() if value == relationship["target_column"]), relationship["target_column"]),
            "confidence": relationship.get("confidence"),
        })
    return {"tables": tables, "deterministic_relationships": relationships}, aliases


def _extract_json(text: str | None) -> dict[str, Any] | None:
    if not text:
        return None
    candidate = text.strip()
    if candidate.startswith("```"):
        candidate = candidate.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    try:
        value = json.loads(candidate)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        start, end = candidate.find("{"), candidate.rfind("}")
        if start >= 0 and end > start:
            try:
                value = json.loads(candidate[start:end + 1])
                return value if isinstance(value, dict) else None
            except json.JSONDecodeError:
                return None
    return None


def _remap(value: Any, aliases: dict[str, str]) -> Any:
    if isinstance(value, dict):
        return {key: _remap(item, aliases) for key, item in value.items()}
    if isinstance(value, list):
        return [_remap(item, aliases) for item in value]
    if isinstance(value, str):
        return aliases.get(value, value)
    return value


def _valid_references(analysis: dict[str, Any], result: dict[str, Any]) -> bool:
    tables = {dataset["name"] for dataset in result.get("datasets", [])}
    columns = {
        (dataset["name"], entry["column"])
        for dataset in result.get("datasets", [])
        for entry in dataset["profile"].get("schema", [])
    }
    for item in analysis.get("dataset_roles", []):
        if item.get("table") not in tables:
            return False
        for column in item.get("key_candidates", []) + item.get("measures", []):
            if (item["table"], column) not in columns:
                return False
    for item in analysis.get("relationships", []):
        if (item.get("source_table"), item.get("source_column")) not in columns:
            return False
        if (item.get("target_table"), item.get("target_column")) not in columns:
            return False
    return True


def _fallback_diagnostics(reason: str) -> dict[str, Any]:
    return {
        "ai_used": False,
        "gemini_attempted": False,
        "fallback_used": True,
        "agent": "deterministic schema profiler",
        "diagnostic": reason,
    }


def _readable_report(result: dict[str, Any]) -> str:
    recommendation = result["model_recommendation"]
    lines = [
        "DETAIL ANALYSIS REPORT",
        "======================",
        f"Datasets analyzed: {result['dataset_count']}",
        f"Analysis source: {result.get('source_platform', 'local')}",
        f"Reasoning: {'Gemini interpretation' if result.get('diagnostics', {}).get('ai_used') else 'deterministic fallback'}",
        "",
        "DATASET OVERVIEW",
        "-----------------",
        "Dataset | Rows | Columns | Suggested role | Grain / key",
    ]
    roles = {item["table"]: item for item in result.get("agent_analysis", {}).get("dataset_roles", [])}
    for dataset in result.get("datasets", []):
        name = dataset["name"]
        role = roles.get(name, {})
        suggested = role.get("role") or ("fact_table" if name in recommendation["fact_tables"] else "dimension_table" if name in recommendation["dimension_tables"] else "reference_table")
        profile = dataset["profile"]
        lines.append(f"{name} | {dataset['rows']:,} | {dataset['columns']} | {suggested} | {role.get('grain') or profile['dataset_overview']['grain']}")
    lines += ["", "MODEL RECOMMENDATION", "---------------------", f"Fact table(s): {', '.join(recommendation['fact_tables']) or 'None confidently identified'}", f"Dimension table(s): {', '.join(recommendation['dimension_tables']) or 'None confidently identified'}"]
    summary = result.get("agent_analysis", {}).get("executive_summary")
    if summary:
        lines += [f"AI interpretation: {summary}"]
    lines += ["", "RELATIONSHIPS"]
    relationships = result.get("agent_analysis", {}).get("relationships") or result.get("relationships", [])
    if relationships:
        for item in relationships:
            lines.append(f"{item.get('source_table')}.[{item.get('source_column')}] -> {item.get('target_table')}.[{item.get('target_column')}] (confidence {item.get('confidence', 'n/a')})")
    else:
        lines.append("No relationship was confidently detected from the supplied metadata.")
    lines += ["", "DATA QUALITY NOTES"]
    for dataset in result.get("datasets", []):
        profile = dataset["profile"]
        for issue in profile.get("invalid_or_suspicious_values", [])[:5]:
            lines.append(f"{dataset['name']} / {issue['column']}: {issue['issue']}")
        for issue in profile.get("categorical_inconsistencies", [])[:5]:
            lines.append(f"{dataset['name']} / {issue['column']}: inconsistent casing/whitespace variants detected")
    lines += ["", "ASSUMPTIONS AND NEXT STEPS", "--------------------------", "This is a proposed analytical model based on metadata and observed key evidence; confirm business grain before building production joins."]
    if result.get("ignored_files"):
        lines += ["", "Ignored files: " + ", ".join(result["ignored_files"])]
    return "\n".join(lines)


async def enrich_detail_analysis(result: dict[str, Any]) -> dict[str, Any]:
    """Ask Gemini to interpret the deterministic model, with safe fallback."""
    enabled = os.getenv("DETAIL_ANALYSIS_GEMINI_ENABLED", "true").casefold() == "true"
    if not enabled:
        result["diagnostics"] = _fallback_diagnostics("Gemini detail-analysis interpretation is disabled by configuration.")
        result["readable_report"] = _readable_report(result)
        return result
    payload, aliases = _metadata_payload(result)
    prompt = (
        "You are a senior data modeler. Interpret ONLY this metadata-only JSON. "
        "Do not invent table or column names. A numeric attribute such as age, cost, or selling_price "
        "does not make an entity table a fact table. Prefer the table whose rows represent business events "
        "as the fact table. Return JSON only with keys: executive_summary, dataset_roles, relationships, "
        "star_schema, data_quality_findings, assumptions, next_steps. dataset_roles items must include "
        "table, role, confidence, grain, reason, key_candidates, measures. roles are fact_table, "
        "dimension_table, bridge_table, reference_table, or unknown.\n\nMETADATA:\n" + json.dumps(_json_safe(payload))
    )
    result["diagnostics"] = {
        "ai_used": False,
        "gemini_attempted": False,
        "fallback_used": True,
        "agent": "Gemini detail schema agent",
        "values_sent_to_ai": False,
        "columns_sent_to_ai": sum(dataset["columns"] for dataset in result.get("datasets", [])),
    }
    if strict_enabled() and os.getenv("DETAIL_ANALYSIS_ALLOW_METADATA_AI", "false").casefold() != "true":
        result["diagnostics"]["diagnostic"] = "Strict local-only mode kept the metadata agent disabled; deterministic fallback used."
        result["readable_report"] = _readable_report(result)
        return result
    try:
        result["diagnostics"]["gemini_attempted"] = True
        agent = LlmAgent(name="detail_schema_agent", model=MODEL, instruction="Return strict JSON only.", description="Interprets a metadata-only dataset model.")
        raw = await _run_single_agent(agent, "detail_analysis_schema_app", prompt)
        analysis = _extract_json(raw)
        if analysis is None:
            raise ValueError("Gemini returned invalid JSON.")
        analysis = _remap(analysis, aliases)
        if not _valid_references(analysis, result):
            raise ValueError("Gemini returned a table or column reference not present in the supplied metadata.")
        result["agent_analysis"] = analysis
        result["diagnostics"].update({"ai_used": True, "fallback_used": False, "diagnostic": "Gemini interpreted the metadata-only model."})
    except Exception as exc:
        result["diagnostics"]["diagnostic"] = f"Gemini unavailable or rejected: {exc}"
    result["readable_report"] = _readable_report(result)
    return result
