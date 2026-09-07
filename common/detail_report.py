"""Readable, sectioned report for multi-dataset profiling.

The report is generated locally from deterministic observations. It is kept
separate from the Gemini schema interpretation so narrative reasoning cannot
alter measured counts or fabricate quality findings.
"""

from __future__ import annotations

from html import escape
from typing import Any

import pandas as pd


def _fmt(value: Any) -> str:
    if isinstance(value, float):
        return f"{value:,.2f}".rstrip("0").rstrip(".")
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def _table(headers: list[str], rows: list[list[Any]]) -> str:
    head = "".join(f"<th>{escape(str(item))}</th>" for item in headers)
    body = "".join(
        "<tr>" + "".join(f"<td>{escape(_fmt(item))}</td>" for item in row) + "</tr>"
        for row in rows
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def _list(items: list[str]) -> str:
    if not items:
        return "<p>None observed.</p>"
    return "<ul>" + "".join(f"<li>{escape(str(item))}</li>" for item in items) + "</ul>"


def _key_for(profile: dict[str, Any]) -> dict[str, Any] | None:
    candidates = profile.get("primary_key_candidates", [])
    if candidates:
        return next((entry for entry in profile["schema"] if entry["column"] == candidates[0]), None)
    id_like = [entry for entry in profile["schema"] if entry["role"] == "identifier"]
    return max(id_like, key=lambda entry: entry.get("unique", 0), default=None)


def _grain(name: str, profile: dict[str, Any], key: dict[str, Any] | None) -> str:
    low = name.casefold()
    if any(token in low for token in ("order", "sale", "transaction", "fact")):
        return f"One business event / line item per {key['column']}." if key else "One business event or line item per row."
    if any(token in low for token in ("customer", "product", "region", "dimension", "dim")):
        return f"One entity record per {key['column']}." if key else "One entity record per row."
    return profile["dataset_overview"]["grain"]


def _schema_note(entry: dict[str, Any], series: pd.Series) -> str:
    notes: list[str] = []
    if entry.get("key_candidate"):
        notes.append(f"{entry['unique']:,}/{entry['non_null']:,} unique")
    if entry.get("missing"):
        notes.append(f"{entry['missing']:,} blank")
    if entry.get("role") == "categorical":
        values = list(dict.fromkeys(series.dropna().astype(str).head(8).tolist()))
        if values:
            notes.append(", ".join(values))
    if entry.get("role") == "numeric_measure":
        numeric = pd.to_numeric(series, errors="coerce").dropna()
        if not numeric.empty:
            notes.append(f"range {_fmt(float(numeric.min()))} to {_fmt(float(numeric.max()))}")
    if entry.get("role") == "datetime":
        parsed = pd.to_datetime(series, errors="coerce")
        invalid = int(series.notna().sum() - parsed.notna().sum())
        if invalid:
            notes.append(f"{invalid:,} invalid date value(s)")
    return "; ".join(notes)


def build_detail_report_data(result: dict[str, Any], tables: dict[str, pd.DataFrame]) -> dict[str, Any]:
    datasets = result.get("datasets", [])
    overview = [[item["name"], item["rows"], item["columns"]] for item in datasets]
    schema: dict[str, list[list[Any]]] = {}
    grains: list[str] = []
    keys: list[list[Any]] = []
    missing: list[list[Any]] = []
    duplicates: list[str] = []
    suspicious: list[str] = []
    inconsistencies: list[str] = []
    for item in datasets:
        name = item["name"]
        frame = tables[name]
        profile = item["profile"]
        key = _key_for(profile)
        schema[name] = [
            [entry["column"], entry["dtype"], _schema_note(entry, frame[entry["column"]])]
            for entry in profile["schema"]
        ]
        grains.append(f"{name}: {_grain(name, profile, key)}")
        if key:
            duplicate_rows = int(frame.duplicated(subset=[key["column"]], keep=False).sum())
            keys.append([name, key["column"], f"{key['unique']:,}/{key['non_null']:,} non-null values are unique; {duplicate_rows:,} rows share a key value."])
        else:
            keys.append([name, "None confidently identified", "No reliable identifier-like key was observed."])
        for entry in profile["schema"]:
            if entry["missing"]:
                missing.append([name, entry["column"], entry["missing"]])
        exact_duplicates = int(frame.duplicated().sum())
        if exact_duplicates:
            duplicates.append(f"{name}: {exact_duplicates:,} exact duplicate row(s).")
        else:
            duplicates.append(f"{name}: no exact duplicate rows observed.")
        for issue in profile.get("invalid_or_suspicious_values", []):
            suspicious.append(f"{name} / {issue['column']}: {issue['issue']}")
        for issue in profile.get("categorical_inconsistencies", []):
            variants = "; ".join(", ".join(values) for values in issue.get("variants", [])[:3])
            inconsistencies.append(f"{name} / {issue['column']}: casing or whitespace variants ({variants}).")

    relation_rows: list[list[Any]] = []
    relationship_notes: list[str] = []
    for relation in result.get("relationships", []):
        source = tables[relation["source_table"]][relation["source_column"]]
        target = tables[relation["target_table"]][relation["target_column"]]
        source_values = set(source.dropna().astype(str).str.strip())
        target_values = set(target.dropna().astype(str).str.strip())
        orphan_count = len(source_values - target_values)
        missing_source = int(source.isna().sum())
        target_coverage = len(source_values & target_values) / len(target_values) if target_values else 0
        relation_rows.append([
            f"{relation['source_table']}.{relation['source_column']}",
            f"{relation['target_table']}.{relation['target_column']}",
            relation.get("confidence", "n/a"),
            f"{missing_source:,} blank; {orphan_count:,} orphan value(s)",
        ])
        relationship_notes.append(
            f"{relation['source_table']}.{relation['source_column']} -> {relation['target_table']}.{relation['target_column']}: "
            f"{orphan_count:,} orphan value(s); target coverage {target_coverage:.0%}."
        )

    fact_tables = result["model_recommendation"].get("fact_tables", [])
    dimension_tables = result["model_recommendation"].get("dimension_tables", [])
    measures = []
    for name in fact_tables:
        measures.extend(entry["column"] for entry in next(item for item in datasets if item["name"] == name)["profile"]["schema"] if entry["role"] == "numeric_measure")
    schema_lines = []
    for fact in fact_tables:
        schema_lines.append(f"{fact} (fact table)\n  Measures: {', '.join(measures) or 'none detected'}")
        for relation in result.get("relationships", []):
            if relation["source_table"] == fact:
                schema_lines.append(f"  -> {relation['target_table']} via {relation['source_column']} = {relation['target_column']}")
    for dimension in dimension_tables:
        schema_lines.append(f"{dimension} (dimension table)")

    assumptions = [
        "Duplicate rows are treated as possible load errors until business rules confirm they are real events.",
        "Key and relationship proposals are based on metadata, identifier semantics, and observed value overlap.",
        "Numeric attributes such as age, cost, and selling price do not by themselves make a table a fact table.",
        "The proposed star schema should be confirmed against business definitions before production joins are built.",
    ]
    next_steps = [
        "Agree on duplicate-row handling and the business grain of each source.",
        "Decide how missing foreign keys and suspicious numeric/date values should be treated.",
        "Standardize categorical values and validate the proposed relationships.",
        "Build the typed fact and dimension tables only after the cleaning contract is approved.",
    ]
    return {
        "overview": overview,
        "schema": schema,
        "grains": grains,
        "keys": keys,
        "relationships": relation_rows,
        "relationship_notes": relationship_notes,
        "missing": missing,
        "duplicates": duplicates,
        "suspicious": suspicious,
        "inconsistencies": inconsistencies,
        "fact_tables": fact_tables,
        "dimension_tables": dimension_tables,
        "measures": measures,
        "star_schema": "\n".join(schema_lines) or "No star schema candidate was identified.",
        "assumptions": assumptions,
        "next_steps": next_steps,
    }


def render_detail_report(result: dict[str, Any]) -> str:
    report = result["detail_report"]
    role = "Gemini interpretation" if result.get("diagnostics", {}).get("ai_used") else "deterministic fallback"
    sections = [
        "<h1>Dataset Detail Analysis</h1>",
        f"<p class='report-meta'><strong>{escape(str(result.get('dataset_count', 0)))}</strong> datasets analyzed · Reasoning: <strong>{role}</strong></p>",
        "<h2>1. Rows and columns</h2>", _table(["File", "Data rows", "Columns"], report["overview"]),
        "<p class='muted'>Counts describe the supplied datasets. No raw data rows are returned in this report.</p>",
    ]
    for name, rows in report["schema"].items():
        sections += [f"<h2>2. Schema: {escape(name)}</h2>", _table(["Column", "Inferred type", "Notes"], rows)]
    sections += ["<h2>3. Likely grain</h2>", _list(report["grains"]), "<h2>4. Likely primary keys</h2>", _table(["Dataset", "Proposed PK", "Evidence"], report["keys"]), "<h2>5. Foreign keys and relationships</h2>"]
    sections += [_table(["From", "To", "Confidence", "Integrity evidence"], report["relationships"])] if report["relationships"] else ["<p>No relationship was confidently detected.</p>"]
    sections += [_list(report["relationship_notes"]), "<h2>6. Missing values</h2>"]
    sections += [_table(["File", "Column", "Missing"], report["missing"])] if report["missing"] else ["<p>All supplied columns are complete.</p>"]
    sections += ["<h2>7. Duplicate records</h2>", _list(report["duplicates"]), "<h2>8. Invalid or suspicious values</h2>", _list(report["suspicious"]), "<h2>9. Inconsistent categorical values</h2>", _list(report["inconsistencies"]), "<h2>10. Other data-quality observations</h2>", "<p>Review the schema notes, missing-key counts, duplicate evidence, and relationship integrity above before modeling.</p>", "<h2>11. Fact table</h2>", _list([f"{name} holds event-level rows and measures." for name in report["fact_tables"]]), "<h2>12. Dimension tables</h2>", _list([f"{name} provides descriptive attributes." for name in report["dimension_tables"]]), "<h2>13. Proposed star schema</h2>", f"<pre class='schema-diagram'>{escape(report['star_schema'])}</pre>", "<h2>14. Assumptions and recommendation</h2>", _list(report["assumptions"]), "<h3>Recommended next step</h3>", _list(report["next_steps"])]
    if result.get("agent_analysis", {}).get("executive_summary"):
        sections.insert(2, f"<section class='ai-summary'><strong>AI model interpretation:</strong> {escape(result['agent_analysis']['executive_summary'])}</section>")
    if result.get("ignored_files"):
        sections += ["<h2>Ignored files</h2>", _list(result["ignored_files"])]
    return "\n".join(sections)
