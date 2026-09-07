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


def _agent_bullets(value: Any) -> list[str]:
    """Turn flexible agent output into readable bullets without raw JSON."""
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        if "explanation" in value:
            return [f"{value.get('title', 'Finding')}: {value['explanation']}"]
        return [f"{key}: {item}" for key, item in value.items()]
    if isinstance(value, list):
        bullets: list[str] = []
        for item in value:
            bullets.extend(_agent_bullets(item))
        return bullets
    return [str(value)]


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
    ranges: list[str] = []
    invalid_dates: list[str] = []
    categorical_values: list[list[Any]] = []
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
        if key:
            duplicate_key_values = frame[key["column"]].dropna().astype(str).value_counts()
            duplicate_key_values = duplicate_key_values[duplicate_key_values > 1]
            if len(duplicate_key_values):
                sample_ids = ", ".join(duplicate_key_values.head(8).index.tolist())
                duplicates.append(f"{name}: {len(duplicate_key_values):,} duplicate {key['column']} value group(s); examples: {sample_ids}.")
        if exact_duplicates:
            duplicates.append(f"{name}: {exact_duplicates:,} exact duplicate row(s).")
        else:
            duplicates.append(f"{name}: no exact duplicate rows observed.")
        for issue in profile.get("invalid_or_suspicious_values", []):
            suspicious.append(f"{name} / {issue['column']}: {issue['issue']}")
        for issue in profile.get("categorical_inconsistencies", []):
            variants = "; ".join(", ".join(values) for values in issue.get("variants", [])[:3])
            inconsistencies.append(f"{name} / {issue['column']}: casing or whitespace variants ({variants}).")
        for entry in profile["schema"]:
            if entry["role"] == "categorical" and entry["unique"] <= 20:
                counts = frame[entry["column"]].dropna().astype(str).value_counts().head(20)
                categorical_values.extend(
                    [name, entry["column"], value, int(count)]
                    for value, count in counts.items()
                )
        for entry in profile["schema"]:
            series = frame[entry["column"]]
            if entry["role"] == "numeric_measure":
                numeric = pd.to_numeric(series, errors="coerce").dropna()
                if not numeric.empty:
                    ranges.append(f"{name} / {entry['column']}: {_fmt(float(numeric.min()))} to {_fmt(float(numeric.max()))}.")
            if entry["role"] == "datetime" or any(token in entry["column"].casefold() for token in ("date", "time", "timestamp")):
                parsed = pd.to_datetime(series, errors="coerce")
                invalid_mask = series.notna() & parsed.isna()
                if int(invalid_mask.sum()):
                    examples = ", ".join(series[invalid_mask].astype(str).head(8).tolist())
                    invalid_dates.append(f"{name} / {entry['column']}: {int(invalid_mask.sum()):,} invalid value(s), examples: {examples}.")

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
    formula_findings: list[str] = []
    category_mismatches: list[str] = []
    for name, frame in tables.items():
        low_columns = {str(column).casefold(): column for column in frame.columns}
        if {"quantity", "discount", "sales_amount"}.issubset(low_columns):
            quantity = pd.to_numeric(frame[low_columns["quantity"]], errors="coerce")
            discount = pd.to_numeric(frame[low_columns["discount"]], errors="coerce")
            sales = pd.to_numeric(frame[low_columns["sales_amount"]], errors="coerce")
            negative_quantity = int((quantity < 0).sum())
            negative_sales = int((sales < 0).sum())
            if negative_quantity:
                formula_findings.append(f"{name}: {negative_quantity:,} row(s) have negative quantity; these also need review as returns/cancellations or sign errors.")
            if negative_sales:
                formula_findings.append(f"{name}: {negative_sales:,} row(s) have negative sales_amount.")
            if "selling_price" in low_columns and "product_id" in low_columns:
                formula_findings.append(f"{name}: sales_amount can be checked as selling_price x quantity x (1 - discount) after joining products.")
        if "profit" in low_columns:
            profit = pd.to_numeric(frame[low_columns["profit"]], errors="coerce")
            negative_profit = int((profit < 0).sum())
            if negative_profit:
                formula_findings.append(f"{name}: {negative_profit:,} row(s) have negative profit; verify whether this is a valid margin or a data issue.")
        category = next((column for key, column in low_columns.items() if key in {"category", "product_category"}), None)
        subcategory = next((column for key, column in low_columns.items() if key in {"sub_category", "subcategory", "product_subcategory"}), None)
        if category and subcategory:
            grouped = frame[[category, subcategory]].dropna().astype(str)
            if not grouped.empty:
                dominant = grouped.groupby(category)[subcategory].agg(lambda values: values.mode().iloc[0] if not values.mode().empty else "")
                mismatch = grouped[grouped.apply(lambda row: row[subcategory] != dominant.get(row[category], row[subcategory]), axis=1)]
                if len(mismatch):
                    category_mismatches.append(f"{name}: {len(mismatch):,} category/sub-category combination(s) differ from the dominant category family; inspect before standardizing.")

    # Verify common order/catalog formulas when the required columns exist.
    order_name = next((name for name, frame in tables.items() if {"product_id", "quantity", "discount", "sales_amount"}.issubset({str(column).casefold() for column in frame.columns})), None)
    product_name = next((name for name, frame in tables.items() if {"product_id", "cost", "selling_price"}.issubset({str(column).casefold() for column in frame.columns})), None)
    if order_name and product_name:
        orders = tables[order_name]
        products = tables[product_name]
        order_columns = {str(column).casefold(): column for column in orders.columns}
        product_columns = {str(column).casefold(): column for column in products.columns}
        catalog = products[[product_columns["product_id"], product_columns["cost"], product_columns["selling_price"]]].drop_duplicates(product_columns["product_id"])
        joined = orders.merge(catalog, left_on=order_columns["product_id"], right_on=product_columns["product_id"], how="inner")
        quantity = pd.to_numeric(joined[order_columns["quantity"]], errors="coerce")
        discount = pd.to_numeric(joined[order_columns["discount"]], errors="coerce")
        expected_sales = pd.to_numeric(joined[product_columns["selling_price"]], errors="coerce") * quantity * (1 - discount)
        actual_sales = pd.to_numeric(joined[order_columns["sales_amount"]], errors="coerce")
        sales_ok = expected_sales.notna() & actual_sales.notna()
        if int(sales_ok.sum()):
            mismatches = int(((expected_sales[sales_ok] - actual_sales[sales_ok]).abs() > 0.01).sum())
            formula_findings.append(f"{order_name}: sales_amount = selling_price x quantity x (1 - discount) verified on {int(sales_ok.sum()):,} joinable rows; {mismatches:,} mismatch(es).")
        if "cost_amount" in order_columns:
            expected_cost = pd.to_numeric(joined[product_columns["cost"]], errors="coerce") * quantity.abs()
            actual_cost = pd.to_numeric(joined[order_columns["cost_amount"]], errors="coerce")
            cost_ok = expected_cost.notna() & actual_cost.notna()
            if int(cost_ok.sum()):
                mismatches = int(((expected_cost[cost_ok] - actual_cost[cost_ok]).abs() > 0.01).sum())
                formula_findings.append(f"{order_name}: cost_amount = product.cost x abs(quantity) verified on {int(cost_ok.sum()):,} joinable rows; {mismatches:,} mismatch(es).")
        if "profit" in order_columns:
            expected_profit = quantity * (pd.to_numeric(joined[product_columns["selling_price"]], errors="coerce") * (1 - discount) - pd.to_numeric(joined[product_columns["cost"]], errors="coerce"))
            actual_profit = pd.to_numeric(joined[order_columns["profit"]], errors="coerce")
            profit_ok = expected_profit.notna() & actual_profit.notna()
            if int(profit_ok.sum()):
                mismatches = int(((expected_profit[profit_ok] - actual_profit[profit_ok]).abs() > 0.01).sum())
                formula_findings.append(f"{order_name}: profit formula verified on {int(profit_ok.sum()):,} joinable rows; {mismatches:,} mismatch(es).")
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
        "invalid_dates": invalid_dates,
        "ranges": ranges,
        "formula_findings": formula_findings,
        "category_mismatches": category_mismatches,
        "categorical_values": categorical_values,
        "fact_tables": fact_tables,
        "dimension_tables": dimension_tables,
        "measures": measures,
        "star_schema": "\n".join(schema_lines) or "No star schema candidate was identified.",
        "star_links": [
            {
                "dimension": relation["target_table"],
                "fact_column": relation["source_column"],
                "dimension_column": relation["target_column"],
            }
            for relation in result.get("relationships", [])
            if relation["source_table"] in fact_tables
            and relation["target_table"] in dimension_tables
        ],
        "assumptions": assumptions,
        "next_steps": next_steps,
    }


def render_detail_report(result: dict[str, Any]) -> str:
    report = result["detail_report"]
    role = "Gemini interpretation" if result.get("diagnostics", {}).get("ai_used") else "deterministic fallback"
    agent = result.get("agent_analysis", {})
    ai_quality = _agent_bullets(agent.get("other_data_quality_observations"))
    ai_fact = _agent_bullets(agent.get("fact_table_analysis"))
    ai_dimensions = _agent_bullets(agent.get("dimension_table_analysis"))
    quality_section = ai_quality if ai_quality else [
        "The report is using deterministic quality evidence because Gemini metadata interpretation was unavailable.",
        "Review missing keys, duplicate records, formula checks, and categorical inconsistencies before modeling.",
    ]
    fact_section = ai_fact or [
        f"{name} is the fact-table candidate because it contains repeated event-level rows, foreign keys, and numeric measures."
        for name in report["fact_tables"]
    ]
    dimension_section = ai_dimensions or [
        f"{name} is a dimension-table candidate because it describes a reusable entity and is joined by an identifier."
        for name in report["dimension_tables"]
    ]
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
    sections += [
        "<h2>7. Duplicate records</h2>", _list(report["duplicates"]),
        "<h2>8. Invalid or suspicious values</h2>",
        "<h3>Invalid dates</h3>", _list(report["invalid_dates"]),
        "<h3>Numeric and measure checks</h3>", _list(report["formula_findings"]),
        "<h3>Other numeric ranges</h3>", _list(report["ranges"]),
        "<h2>9. Inconsistent categorical values</h2>", _list(report["inconsistencies"]),
        "<h3>Observed categorical distributions</h3>",
        _table(["Dataset", "Column", "Raw value", "Count"], report["categorical_values"]) if report["categorical_values"] else "<p>No low-cardinality categorical fields were observed.</p>",
        "<h3>Category/sub-category mismatches</h3>", _list(report["category_mismatches"]),
        "<h2>10. Other data-quality observations</h2>", _list(quality_section),
        "<h2>11. Fact table</h2>", _list(fact_section),
        "<h2>12. Dimension tables</h2>", _list(dimension_section),
        "<h2>13. Proposed star schema</h2>", _star_schema_diagram(report),
        "<h2>14. Assumptions and recommendation</h2>", _list(report["assumptions"]),
        "<h3>Recommended next step</h3>", _list(report["next_steps"]),
    ]
    if result.get("agent_analysis", {}).get("executive_summary"):
        sections.insert(2, f"<section class='ai-summary'><strong>AI model interpretation:</strong> {escape(result['agent_analysis']['executive_summary'])}</section>")
    if result.get("ignored_files"):
        sections += ["<h2>Ignored files</h2>", _list(result["ignored_files"])]
    return "\n".join(sections)


def _star_schema_diagram(report: dict[str, Any]) -> str:
    """Render a visual star: fact in the center, dimensions around it."""
    fact = report["fact_tables"][0] if report["fact_tables"] else "Fact table"
    measures = ", ".join(report.get("measures", [])) or "none detected"
    dimensions = report.get("dimension_tables", [])
    links = {item["dimension"]: item for item in report.get("star_links", [])}
    cards = [
        "<div class='star-center'>"
        f"<strong>{escape(fact)}</strong><span>FACT TABLE</span>"
        f"<small>Measures: {escape(measures)}</small>"
        "</div>"
    ]
    for index, dimension in enumerate(dimensions):
        link = links.get(dimension, {})
        cards.append(
            f"<div class='star-dimension star-dimension-{index % 4}'>"
            f"<strong>{escape(dimension)}</strong><span>DIMENSION TABLE</span>"
            f"<small>{escape(str(link.get('dimension_column', 'key')))}</small>"
            f"<em>fact join: {escape(str(link.get('fact_column', 'join key')))}</em>"
            "</div>"
        )
    if not dimensions:
        cards.append("<p class='muted'>No dimension table was confidently identified.</p>")
    return "<div class='star-schema-diagram'>" + "".join(cards) + "</div>"
