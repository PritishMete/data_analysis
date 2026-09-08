"""Privacy-safe planning and local analyst narrative primitives.

The planner is deliberately small: it decides *which* existing local
capability to run, while profiling and all evidence remain local.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import re
from typing import Any

import pandas as pd


ALLOWED_INTENTS = {
    "data_quality_analysis", "detail_analysis", "cleaning",
    "dimensional_modeling", "business_analysis", "aggregation", "ranking",
    "trend_analysis", "dashboard", "explanation", "follow_up", "unknown",
}
ALLOWED_OPERATIONS = {
    "duplicate_analysis", "key_integrity", "missing_value_analysis",
    "type_validation", "categorical_consistency", "cross_table_consistency",
    "cross_table_temporal_consistency", "safe_deduplication",
    "quality_validation", "aggregate", "rank", "trend_analysis", "dashboard",
}
ALLOWED_ROLES = {
    "dataset", "customer_dimension_candidate", "transaction_fact_candidate",
    "product_dimension_candidate", "region_dimension_candidate",
}
_UNSAFE_MARKERS = {"code", "sql", "python", "shell", "command", "expression", "eval"}

FINDING_ACTION_REGISTRY = {
    "duplicate_records": {"allowed_action": "safe_deduplication", "workflow": "customer_cleaning"},
    "business_key_not_unique": {"allowed_action": "safe_deduplication", "workflow": "customer_cleaning"},
    "conflicting_duplicate_entity": {"allowed_action": "review_only", "workflow": None},
    "invalid_or_suspicious_value": {"allowed_action": "review_only", "workflow": None},
    "categorical_inconsistency": {"allowed_action": "review_only", "workflow": None},
    "missing_values": {"allowed_action": "policy_required", "workflow": None},
    "referential_integrity": {"allowed_action": "review_or_rule_required", "workflow": None},
}

MAX_LOCAL_EXAMPLES = 3


def _local_json_value(value: Any) -> Any:
    if value is None or (not isinstance(value, (list, dict, tuple)) and pd.isna(value)):
        return None
    return value.item() if hasattr(value, "item") else value


@dataclass(frozen=True)
class ChatAnalysisPlan:
    intent: str
    dataset_scope: tuple[str, ...]
    operations: tuple[str, ...]
    comparison_scope: tuple[str, ...]
    response_mode: str = "analyst_explanation"
    response_depth: str = "standard"
    mutation_requested: bool = False
    confidence: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["dataset_scope"] = list(self.dataset_scope)
        value["operations"] = list(self.operations)
        value["comparison_scope"] = list(self.comparison_scope)
        return value


def _as_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValueError(f"{field} must be a list of strings")
    return value


def validate_chat_plan(
    value: Any,
    available_roles: set[str] | None = None,
    *,
    available_operations: set[str] | None = None,
    mutation_allowed: bool = False,
) -> ChatAnalysisPlan:
    if not isinstance(value, dict):
        raise ValueError("Planner output must be a JSON object")
    forbidden = set(value) & _UNSAFE_MARKERS
    if forbidden:
        raise ValueError("Planner output contains an unsafe execution field")
    intent = value.get("intent")
    if intent not in ALLOWED_INTENTS:
        raise ValueError("Planner intent is not allowlisted")
    roles = available_roles or ALLOWED_ROLES
    scope = tuple(dict.fromkeys(_as_list(value.get("dataset_scope"), "dataset_scope")))
    comparison = tuple(dict.fromkeys(_as_list(value.get("comparison_scope"), "comparison_scope")))
    operations = tuple(dict.fromkeys(_as_list(value.get("operations"), "operations")))
    if any(item not in roles or item not in ALLOWED_ROLES for item in (*scope, *comparison)):
        raise ValueError("Planner referenced an unavailable dataset role")
    if any(item not in ALLOWED_OPERATIONS or (available_operations is not None and item not in available_operations) for item in operations):
        raise ValueError("Planner requested an unavailable operation")
    mutation = value.get("mutation_requested", False)
    if not isinstance(mutation, bool) or (mutation and not mutation_allowed):
        raise ValueError("Mutation is not permitted in this planning context")
    confidence = value.get("confidence", 0.0)
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        raise ValueError("Planner confidence must be between 0 and 1")
    response_mode = value.get("response_mode", "analyst_explanation")
    if response_mode not in {"analyst_explanation", "structured", "confirmation"}:
        raise ValueError("Planner response mode is not allowlisted")
    response_depth = value.get("response_depth", "standard")
    if response_depth not in {"concise", "standard", "detailed", "full_report"}:
        raise ValueError("Planner response depth is not allowlisted")
    return ChatAnalysisPlan(intent, scope, operations, comparison, response_mode, response_depth, mutation, float(confidence))


def _tokens(query: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", query.casefold()))


def _role_for(tokens: set[str]) -> str | None:
    if tokens & {"customer", "customers", "client", "clients"}:
        return "customer_dimension_candidate"
    if tokens & {"product", "products", "sku", "catalog"}:
        return "product_dimension_candidate"
    if tokens & {"order", "orders", "transaction", "transactions", "sales"}:
        return "transaction_fact_candidate"
    if tokens & {"region", "regions", "territory", "territories"}:
        return "region_dimension_candidate"
    return None


def deterministic_chat_plan(
    query: str,
    available_roles: set[str] | None = None,
    available_operations: list[str] | None = None,
) -> ChatAnalysisPlan:
    tokens = _tokens(query)
    depth = "full_report" if tokens & {"full", "complete", "report", "profiling"} else "detailed" if tokens & {"detailed", "explain", "explanation"} else "concise" if tokens & {"quickly", "biggest", "highest", "most"} else "standard"
    scope = _role_for(tokens)
    if scope and tokens & {"clean", "cleaning", "fix", "standardize", "deduplicate"}:
        return ChatAnalysisPlan("cleaning", (scope,), ("quality_validation",), confidence=.92, response_depth=depth)
    if tokens & {"dashboard", "visualize", "visualise"}:
        return ChatAnalysisPlan("dashboard", tuple(), ("dashboard",), confidence=.96, response_depth=depth)
    if tokens & {"month", "monthly", "trend", "changing", "change"}:
        return ChatAnalysisPlan("trend_analysis", (scope,) if scope else tuple(), ("trend_analysis",), confidence=.86, response_depth=depth)
    if tokens & {"most", "highest", "top", "profit", "revenue", "sales", "margin"} and not (tokens & {"issue", "issues", "quality", "suspicious", "healthy"}):
        operation = "rank" if tokens & {"most", "highest", "top"} else "aggregate"
        return ChatAnalysisPlan("business_analysis", (scope,) if scope else tuple(), (operation,), confidence=.82, response_depth=depth)
    if scope or tokens & {"quality", "issues", "issue", "suspicious", "reliable", "integrity", "healthy", "inspect", "review"}:
        operations = ("duplicate_analysis", "key_integrity", "missing_value_analysis", "type_validation", "categorical_consistency", "quality_validation")
        comparison = tuple(role for role in (available_roles or ALLOWED_ROLES) if role != scope and role != "dataset")
        if comparison:
            operations += ("cross_table_consistency", "cross_table_temporal_consistency")
        if available_operations is not None:
            operations = tuple(operation for operation in operations if operation in available_operations)
        return ChatAnalysisPlan("data_quality_analysis", (scope,) if scope else tuple(), operations, comparison, response_depth=depth, confidence=.9)
    return ChatAnalysisPlan("unknown", tuple(), tuple(), response_depth=depth, confidence=.2)


@dataclass(frozen=True)
class AnalysisFinding:
    id: str
    category: str
    severity: str
    title_key: str
    explanation_key: str
    impact_key: str
    evidence: dict[str, Any]
    passed: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class AnalyticalIssue:
    issue_id: str
    scope: str
    issue_family: str
    title: str
    severity: str
    priority_score: float
    summary_facts: tuple[str, ...]
    evidence: dict[str, Any]
    examples: tuple[dict[str, Any], ...]
    impact: str
    recommended_action: str
    source_finding_ids: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["summary_facts"] = list(self.summary_facts)
        value["examples"] = list(self.examples)
        value["source_finding_ids"] = list(self.source_finding_ids)
        return value


def _relationship_title(relation: dict[str, Any], kind: str) -> str:
    source = str(relation.get("source_table", "Source")).replace("_raw", "").replace("_", " ").title()
    target_column = str(relation.get("target_column") or relation.get("source_column") or "entity").replace("_id", "").replace("_key", "").replace("_", " ").strip()
    target = target_column.title() or "Entity"
    return f"{source} with {'missing' if kind == 'null' else 'unknown'} {target} references"


def _dataset_label(name: str) -> str:
    label = name.replace("_raw", "").replace("_", " ").strip()
    return label[:-1].title() if label.casefold().endswith("s") else label.title()


def consolidate_findings(result: dict[str, Any], scope: str | None = None) -> list[AnalyticalIssue]:
    """Translate low-level findings into deduplicated, prioritized analyst issues."""
    findings = build_structured_findings(result, scope)
    issues: list[AnalyticalIssue] = []
    duplicate_groups: dict[str, list[AnalysisFinding]] = {}
    consumed: set[str] = set()
    for finding in findings:
        if finding.category in {"duplicate_records", "business_key_not_unique", "conflicting_duplicate_entity"}:
            dataset = str(finding.evidence.get("dataset", "dataset"))
            duplicate_groups.setdefault(dataset, []).append(finding)
    for dataset, related in duplicate_groups.items():
        exact = next((item for item in related if item.category == "duplicate_records"), None)
        key = next((item for item in related if item.category in {"business_key_not_unique", "conflicting_duplicate_entity"}), None)
        if not exact and not key:
            continue
        evidence = dict(key.evidence if key else exact.evidence)
        if exact:
            evidence["exact_duplicate_excess_rows"] = exact.evidence.get("duplicate_rows", 0)
            evidence["exact_duplicate_group_rows"] = exact.evidence.get("duplicate_rows", 0) * 2
        if key:
            evidence["duplicate_identifier_groups"] = key.evidence.get("duplicate_groups", 0)
            evidence["duplicate_physical_rows"] = key.evidence.get("affected_row_count", 0)
            evidence["duplicate_versions_conflict"] = bool(key.evidence.get("conflicting_fields"))
        title = f"Duplicate {_dataset_label(dataset)} records"
        facts = []
        if key:
            facts.extend([f"{int(evidence.get('duplicate_identifier_groups', 0)):,} identifier group(s) are repeated.", f"The duplicate groups contain {int(evidence.get('duplicate_physical_rows', 0)):,} physical record(s)."])
        if exact:
            facts.append(f"Removing repeated exact copies would remove {int(evidence.get('exact_duplicate_excess_rows', 0)):,} excess row(s).")
        if key and not evidence.get("duplicate_versions_conflict"):
            facts.append("The repeated records are identical rather than conflicting versions.")
        source_ids = tuple(item.id for item in related)
        for item in related: consumed.add(item.id)
        issues.append(AnalyticalIssue(f"duplicate_{len(issues)}", scope or "all", "duplicate_entity", title, "high", 82.0, tuple(facts), evidence, tuple((key or exact).evidence.get("examples", [])[:MAX_LOCAL_EXAMPLES]), "The entity key is not safe for a unique dimension until duplicate copies are resolved.", "Use the existing safe deduplication workflow after confirming the business rule.", source_ids))
    for finding in findings:
        if finding.id in consumed or finding.passed:
            continue
        evidence = dict(finding.evidence)
        if finding.category == "referential_integrity":
            nulls = int(evidence.get("null_fk_count", 0) or 0)
            orphans = int(evidence.get("orphan_fk_count", 0) or 0)
            relation = next((item for item in result.get("relationships", []) if item.get("source_table") == evidence.get("source_table") and item.get("source_column") == evidence.get("source_column")), {})
            source_profile = next((item.get("profile", {}) for item in result.get("datasets", []) if item.get("name") == evidence.get("source_table")), {})
            missing_evidence = next((item for item in source_profile.get("quality_evidence", []) if item.get("finding_type") == "missing_values" and item.get("column") == evidence.get("source_column")), {})
            if missing_evidence.get("example_rows"):
                evidence["examples"] = missing_evidence["example_rows"]
            for kind, count in (("null", nulls), ("orphan", orphans)):
                if not count:
                    continue
                title = _relationship_title(relation or evidence, kind)
                family = "missing_relationship" if kind == "null" else "orphan_relationship"
                issues.append(AnalyticalIssue(f"relationship_{len(issues)}", scope or "all", family, title, "medium" if kind == "null" else "high", 68.0 if kind == "null" else 73.0, (f"{count:,} source record(s) have {'no' if kind == 'null' else 'a non-matching'} foreign-key value.", f"Non-null referential coverage is {float(evidence.get('coverage', relation.get('non_null_referential_coverage', 0)) or 0):.2%}."), {**evidence, "count": count}, tuple(evidence.get("examples", [])[:MAX_LOCAL_EXAMPLES]), "These records cannot be attributed reliably through the relationship.", "Define an explicit null-member or unknown-member handling rule before modeling.", (finding.id,)))
            consumed.add(finding.id)
            continue
        if finding.category == "cross_table_temporal_inconsistency":
            affected = int(evidence.get("affected_row_count", 0) or 0)
            pct = float(evidence.get("affected_percentage", 0) or 0)
            issues.append(AnalyticalIssue(f"temporal_{len(issues)}", scope or "all", "temporal_integrity", "Orders before customer signup", "high" if pct >= 25 else "medium", 95.0 + min(pct, 5), (f"{affected:,} orders occurred before the associated customer signup date.", f"{int(evidence.get('affected_entity_count', 0)):,} customers are affected ({pct:.2f}%)."), evidence, tuple(evidence.get("examples", [])[:MAX_LOCAL_EXAMPLES]), "Customer tenure, acquisition, cohort, and first-purchase analysis may be unreliable.", "Investigate source chronology and define a trusted correction or exclusion rule.", (finding.id,)))
            continue
        title = {"missing_values": "Missing values", "categorical_inconsistency": "Inconsistent category formatting", "invalid_semantic_field": "Invalid semantic field values", "synthetic_pattern": "Synthetic-looking text pattern", "invalid_or_suspicious_value": "Suspicious values"}.get(finding.category, "Data-quality issue")
        severity = "minor" if finding.category == "synthetic_pattern" else "medium"
        score = 20.0 if severity == "minor" else 55.0
        issues.append(AnalyticalIssue(f"issue_{len(issues)}", scope or "all", finding.category, title, severity, score, (f"{int(evidence.get('affected_row_count', evidence.get('missing_rows', 0)) or 0):,} affected record(s) were observed.",), evidence, tuple(evidence.get("examples", [])[:MAX_LOCAL_EXAMPLES]), impacts_for_category(finding.category), "Review the local evidence and approve a rule before changing data.", (finding.id,)))
    return sorted(issues, key=lambda item: (-item.priority_score, item.issue_id))


def impacts_for_category(category: str) -> str:
    return {"missing_values": "Missing values can weaken joins, segmentation, or measures.", "categorical_inconsistency": "Formatting variants can split one business category into multiple groups.", "invalid_semantic_field": "Invalid semantic values reduce trustworthy filtering and analysis.", "synthetic_pattern": "Patterned labels may limit identity-level analysis but are not automatically invalid.", "invalid_or_suspicious_value": "Suspicious values may distort downstream calculations."}.get(category, "Review the locally observed evidence before modeling.")


def _scope_matches(name: str, scope: str | None) -> bool:
    if not scope:
        return True
    words = {"customer": "customer", "product": "product", "order": "order", "region": "region"}
    return words.get(scope, scope) in name.casefold()


def _semantic_column(columns: list[str], role: str) -> str | None:
    terms = {
        "customer_identifier": ({"customer", "client"}, {"id", "key", "code"}),
        "signup_date": ({"signup", "sign", "registration", "registered", "join"}, {"date", "dt"}),
        "order_date": ({"order", "transaction", "sale", "purchase"}, {"date", "dt"}),
    }
    entity, suffix = terms[role]
    for column in columns:
        tokens = set(re.findall(r"[a-z0-9]+", column.casefold()))
        if tokens & entity and tokens & suffix:
            return column
    return None


def build_quality_evidence(tables: dict[str, pd.DataFrame]) -> dict[str, list[dict[str, Any]]]:
    """Build bounded, local evidence from the same frames used for profiling."""
    cache: dict[str, list[dict[str, Any]]] = {}
    for name, frame in tables.items():
        entries: list[dict[str, Any]] = []
        exact = frame[frame.duplicated(keep=False)]
        if not exact.empty:
            entries.append({"finding_type": "duplicate_records", "affected_row_count": int(frame.duplicated().sum()), "example_rows": [{"source_row": int(index) + 2, "values": {str(key): value for key, value in row.items()}} for index, row in exact.head(3).iterrows()]})
        for column in frame.columns:
            missing = frame[column].isna() | frame[column].astype("string").str.strip().eq("")
            if int(missing.sum()):
                entries.append({"finding_type": "missing_values", "column": str(column), "affected_row_count": int(missing.sum()), "example_rows": [{"source_row": int(index) + 2, "values": {str(key): _local_json_value(value) for key, value in frame.loc[index].items()}} for index in frame.index[missing][:MAX_LOCAL_EXAMPLES]]})
            tokens = set(re.findall(r"[a-z0-9]+", str(column).casefold()))
            if tokens & {"id", "key", "code"}:
                non_null = frame.loc[~missing, column].astype("string").str.strip()
                duplicated = non_null[non_null.duplicated(keep=False)]
                if not duplicated.empty:
                    duplicate_groups = frame.loc[~missing].groupby(column, dropna=False)
                    conflicting_fields = sorted({str(field) for _, group in duplicate_groups if len(group) > 1 for field in frame.columns if field != column and group[field].nunique(dropna=False) > 1})
                    entries.append({"finding_type": "duplicate_business_key", "column": str(column), "affected_row_count": int(len(duplicated)), "duplicate_group_count": int(duplicated.nunique()), "conflicting": bool(conflicting_fields), "conflicting_fields": conflicting_fields, "example_rows": [{"source_row": int(index) + 2, "value": value} for index, value in frame.loc[~missing, column].items() if str(value).strip() in set(duplicated.head(3))][:MAX_LOCAL_EXAMPLES]})
            column_values = frame[column].dropna().astype(str).str.strip()
            field_tokens = set(re.findall(r"[a-z0-9]+", str(column).casefold()))
            if field_tokens & {"email", "mail"}:
                invalid = column_values[~column_values.str.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", na=False)]
                if not invalid.empty:
                    entries.append({"finding_type": "invalid_semantic_field", "field_role": "email", "column": str(column), "affected_row_count": int(len(invalid)), "example_rows": [{"source_row": int(index) + 2, "value": value} for index, value in frame[column].items() if str(value).strip() in set(invalid.head(MAX_LOCAL_EXAMPLES))][:MAX_LOCAL_EXAMPLES]})
            if field_tokens & {"phone", "mobile", "telephone", "tel"}:
                digits = column_values.str.replace(r"\D", "", regex=True)
                invalid = column_values[(digits.str.len() < 7) | (digits.str.len() > 15)]
                if not invalid.empty:
                    entries.append({"finding_type": "invalid_semantic_field", "field_role": "phone", "column": str(column), "affected_row_count": int(len(invalid)), "example_rows": [{"source_row": int(index) + 2, "value": value} for index, value in frame[column].items() if str(value).strip() in set(invalid.head(MAX_LOCAL_EXAMPLES))][:MAX_LOCAL_EXAMPLES]})
        for column in frame.columns:
            values = frame[column].dropna().astype(str)
            normalized = values.str.strip().str.casefold()
            field_tokens = set(re.findall(r"[a-z0-9]+", str(column).casefold()))
            if not pd.api.types.is_numeric_dtype(frame[column]) and normalized.nunique() < values.nunique():
                entries.append({"finding_type": "categorical_inconsistency", "column": str(column), "affected_row_count": int(len(values) - normalized.nunique()), "example_rows": [{"source_row": int(index) + 2, "value": value} for index, value in frame[column].items() if value is not None][:MAX_LOCAL_EXAMPLES]})
            if not pd.api.types.is_numeric_dtype(frame[column]) and len(values) >= 2:
                templates = values.str.replace(r"\d+", "{number}", regex=True)
                common = templates.value_counts().head(1)
                if not common.empty and common.iloc[0] / len(values) >= 0.9 and "name" in field_tokens:
                    entries.append({"finding_type": "synthetic_pattern", "column": str(column), "pattern": common.index[0], "affected_row_count": int(common.iloc[0]), "classification": "analytical_limitation", "example_rows": [{"source_row": int(index) + 2, "value": value} for index, value in frame[column].items() if value is not None][:MAX_LOCAL_EXAMPLES]})
        cache[name] = entries
    customer = next((item for item in tables if "customer" in item.casefold()), None)
    orders = next((item for item in tables if any(token in item.casefold() for token in ("order", "transaction", "sales"))), None)
    if customer and orders:
        customer_key = _semantic_column([str(item) for item in tables[customer].columns], "customer_identifier")
        order_key = _semantic_column([str(item) for item in tables[orders].columns], "customer_identifier")
        signup = _semantic_column([str(item) for item in tables[customer].columns], "signup_date")
        order_date = _semantic_column([str(item) for item in tables[orders].columns], "order_date")
        if customer_key and order_key and signup and order_date:
            left = tables[orders].copy()
            right = tables[customer][[customer_key, signup]].copy()
            left["__order_date"] = pd.to_datetime(left[order_date], errors="coerce")
            right["__signup_date"] = pd.to_datetime(right[signup], errors="coerce")
            joined = left.merge(right, left_on=order_key, right_on=customer_key, how="inner")
            bad = joined[joined["__order_date"].notna() & joined["__signup_date"].notna() & (joined["__order_date"] < joined["__signup_date"])]
            if not bad.empty:
                cache.setdefault(customer, []).append({"finding_type": "cross_table_temporal_inconsistency", "related_dataset": orders, "affected_row_count": int(len(bad)), "affected_entity_count": int(bad[order_key].nunique()), "total_entity_count": int(right[customer_key].nunique()), "affected_percentage": round(float(bad[order_key].nunique() / right[customer_key].nunique() * 100), 2) if right[customer_key].nunique() else 0.0, "example_rows": [{"customer": row.get(order_key), "signup_date": str(row.get("__signup_date").date()), "order_date": str(row.get("__order_date").date())} for _, row in bad.head(MAX_LOCAL_EXAMPLES).iterrows()]})
    return cache


def build_structured_findings(result: dict[str, Any], scope: str | None = None) -> list[AnalysisFinding]:
    findings: list[AnalysisFinding] = []
    for dataset in result.get("datasets", []):
        if not _scope_matches(str(dataset.get("name", "")), scope):
            continue
        profile = dataset.get("profile", {})
        evidence_cache = profile.get("quality_evidence", []) or []
        quality = profile.get("quality_summary", {})
        duplicates = int(quality.get("exact_duplicate_rows", 0) or 0)
        if duplicates:
            evidence = next((item for item in evidence_cache if item.get("finding_type") == "duplicate_records"), {})
            findings.append(AnalysisFinding("duplicate_rows", "duplicate_records", "confirmed_issue", "duplicate_records", "exact_duplicate_rows", "duplicate_impact", {"dataset": dataset.get("name"), "duplicate_rows": duplicates, "examples": evidence.get("example_rows", [])}))
        for entry in profile.get("schema", []) or []:
            missing = int(entry.get("missing", 0) or 0)
            if missing:
                evidence = next((item for item in evidence_cache if item.get("finding_type") == "missing_values" and item.get("column") == entry.get("column")), {})
                findings.append(AnalysisFinding(f"missing_{len(findings)}", "missing_values", "confirmed_issue", "missing_values", "missing_value_detail", "missing_value_impact", {"dataset": dataset.get("name"), "column": entry.get("column"), "missing_rows": missing, "examples": evidence.get("example_rows", [])}))
            if entry.get("business_key_candidate") and not entry.get("primary_key_valid", False):
                evidence = next((item for item in evidence_cache if item.get("finding_type") == "duplicate_business_key" and item.get("column") == entry.get("column")), {})
                category = "conflicting_duplicate_entity" if evidence.get("conflicting") else "business_key_not_unique"
                findings.append(AnalysisFinding(f"key_{len(findings)}", category, "confirmed_issue", category, "key_detail", "key_impact", {"dataset": dataset.get("name"), "column": entry.get("column"), "affected_row_count": evidence.get("affected_row_count", 0), "duplicate_groups": evidence.get("duplicate_group_count", 0), "conflicting_fields": evidence.get("conflicting_fields", []), "examples": evidence.get("example_rows", [])}))
        known_key_columns = {str(item.evidence.get("column")) for item in findings if item.category in {"business_key_not_unique", "conflicting_duplicate_entity"}}
        for evidence in evidence_cache:
            if evidence.get("finding_type") != "duplicate_business_key" or evidence.get("column") in known_key_columns:
                continue
            category = "conflicting_duplicate_entity" if evidence.get("conflicting") else "business_key_not_unique"
            findings.append(AnalysisFinding(f"key_{len(findings)}", category, "confirmed_issue", category, "key_detail", "key_impact", {"dataset": dataset.get("name"), "column": evidence.get("column"), "affected_row_count": evidence.get("affected_row_count", 0), "duplicate_groups": evidence.get("duplicate_group_count", 0), "conflicting_fields": evidence.get("conflicting_fields", []), "examples": evidence.get("example_rows", [])}))
        for issue in profile.get("invalid_or_suspicious_values", []) or []:
            findings.append(AnalysisFinding(f"suspicious_{len(findings)}", "invalid_or_suspicious_value", str(issue.get("classification", "needs_review")), "suspicious_values", "suspicious_value_detail", "quality_impact", {"dataset": dataset.get("name"), **issue}))
        for issue in profile.get("categorical_inconsistencies", []) or []:
            findings.append(AnalysisFinding(f"category_{len(findings)}", "categorical_inconsistency", "needs_review", "categorical_inconsistency", "categorical_detail", "category_impact", {"dataset": dataset.get("name"), **issue}))
        for evidence in evidence_cache:
            if evidence.get("finding_type") == "cross_table_temporal_inconsistency":
                findings.append(AnalysisFinding(f"temporal_{len(findings)}", "cross_table_temporal_inconsistency", "confirmed_issue", "temporal_inconsistency", "temporal_detail", "temporal_impact", {**evidence, "examples": evidence.get("example_rows", [])}))
            elif evidence.get("finding_type") == "invalid_semantic_field":
                findings.append(AnalysisFinding(f"semantic_{len(findings)}", "invalid_semantic_field", "confirmed_issue", "invalid_semantic_field", "semantic_field_detail", "semantic_field_impact", {"dataset": dataset.get("name"), **evidence, "examples": evidence.get("example_rows", [])}))
            elif evidence.get("finding_type") == "synthetic_pattern":
                findings.append(AnalysisFinding(f"pattern_{len(findings)}", "synthetic_pattern", "minor_observation", "synthetic_pattern", "synthetic_pattern_detail", "synthetic_pattern_impact", {"dataset": dataset.get("name"), **evidence, "examples": evidence.get("example_rows", [])}))
    for relation in result.get("relationships", []) or []:
        if scope and not _scope_matches(str(relation.get("source_table", "")), scope) and not _scope_matches(str(relation.get("target_table", "")), scope):
            continue
        nulls = int(relation.get("source_nulls", relation.get("null_fk_count", 0)) or 0)
        orphans = int(relation.get("orphan_rows", relation.get("orphan_fk_count", 0)) or 0)
        if nulls or orphans:
            findings.append(AnalysisFinding(f"relationship_{len(findings)}", "referential_integrity", "confirmed_issue", "referential_integrity", "relationship_detail", "relationship_impact", {"source_table": relation.get("source_table"), "source_column": relation.get("source_column"), "target_table": relation.get("target_table"), "target_column": relation.get("target_column"), "null_fk_count": nulls, "orphan_fk_count": orphans, "coverage": relation.get("non_null_referential_coverage")}))
    if not findings:
        findings.append(AnalysisFinding("quality_pass", "quality_checks", "passed", "quality_checks_passed", "quality_checks_detail", "quality_impact", {"datasets": len(result.get("datasets", []))}, True))
    return findings


def build_answer_blueprint(plan: ChatAnalysisPlan | None = None) -> dict[str, Any]:
    """Allowlisted answer shape; Gemini may select this shape but never supplies evidence."""
    return {"sections": ["confirmed_issues", "duplicate_reconciliation", "minor_observations", "passed_checks", "recommendation"], "tone": "professional_analyst", "issue_format": ["title", "severity", "summary", "evidence", "impact", "recommended_action"], "response_depth": plan.response_depth if plan else "standard"}


def compose_analyst_answer(result: dict[str, Any], scope: str | None = None) -> dict[str, Any]:
    findings = build_structured_findings(result, scope)
    analytical_issues = consolidate_findings(result, scope)
    groups = {"confirmed_issue": [], "needs_review": [], "minor_observation": [], "passed": []}
    for finding in findings:
        if finding.passed:
            groups["passed"].append(finding)
        elif finding.severity == "confirmed_issue":
            groups["confirmed_issue"].append(finding)
        elif finding.severity in {"needs_review", "suspicious", "warning"}:
            groups["needs_review"].append(finding)
        else:
            groups["minor_observation"].append(finding)
    labels = {
        "duplicate_records": "Duplicate records",
        "missing_values": "Missing values",
        "business_key_not_unique": "Duplicate business identifiers",
        "conflicting_duplicate_entity": "Conflicting duplicate entities",
        "referential_integrity": "Customer relationship integrity",
        "cross_table_temporal_inconsistency": "Orders before customer signup",
        "invalid_or_suspicious_value": "Suspicious values",
        "categorical_inconsistency": "Inconsistent category formatting",
        "invalid_semantic_field": "Invalid semantic field values",
        "synthetic_pattern": "Synthetic-looking text pattern",
    }
    impacts = {
        "duplicate_records": "Duplicate rows can inflate counts and measures.",
        "business_key_not_unique": "Entity-level joins and dimension uniqueness are not safe until this is resolved.",
        "conflicting_duplicate_entity": "Conflicting attributes make the correct entity version ambiguous.",
        "missing_values": "Missing values can weaken joins, segmentation, or measures.",
        "referential_integrity": "Unmatched or null keys can exclude records from dimensional analysis.",
        "cross_table_temporal_inconsistency": "The chronology issue can distort customer lifecycle and cohort analysis.",
        "invalid_semantic_field": "Invalid contact or semantic values reduce trustworthy filtering and outreach analysis.",
        "categorical_inconsistency": "Formatting variants can split one business category into multiple groups.",
        "synthetic_pattern": "Patterned labels may limit meaningful identity-level analysis, but are not automatically invalid.",
    }
    def human_evidence(finding: AnalysisFinding) -> str:
        evidence = finding.evidence
        count = evidence.get("affected_row_count", evidence.get("duplicate_rows", evidence.get("missing_rows")))
        if count is None and ("null_fk_count" in evidence or "orphan_fk_count" in evidence):
            count = int(evidence.get("null_fk_count", 0) or 0) + int(evidence.get("orphan_fk_count", 0) or 0)
        prefix = f"{count:,} affected record(s)" if isinstance(count, int) else "Observed in the local profile"
        if finding.category == "business_key_not_unique" and evidence.get("duplicate_groups"):
            prefix += f" across {int(evidence['duplicate_groups']):,} duplicate identifier group(s)"
        if finding.category == "cross_table_temporal_inconsistency" and evidence.get("affected_entity_count") is not None:
            prefix += f" across {int(evidence['affected_entity_count']):,} customer(s) ({float(evidence.get('affected_percentage', 0)):.2f}% of customers with valid keys)"
        examples = evidence.get("examples", [])
        if examples:
            rendered = []
            for number, example in enumerate(examples[:MAX_LOCAL_EXAMPLES], 1):
                if isinstance(example, dict):
                    values = example.get("values")
                    if isinstance(values, dict):
                        rendered.append(f"Example {number}: " + "; ".join(f"{key}={value}" for key, value in list(values.items())[:4]))
                    else:
                        rendered.append(f"Example {number}: " + "; ".join(f"{key}={value}" for key, value in example.items() if key not in {"source_row"}))
            if rendered:
                prefix += ". " + ". ".join(rendered)
        return prefix
    def issue_dict(issue: AnalyticalIssue) -> dict[str, Any]:
        return {"title": issue.title, "severity": issue.severity, "priority_score": issue.priority_score, "summary_facts": list(issue.summary_facts), "evidence": issue.evidence, "examples": list(issue.examples), "impact": issue.impact, "recommended_action": issue.recommended_action}
    passed_checks: list[str] = []
    scoped_datasets = [item for item in result.get("datasets", []) if _scope_matches(str(item.get("name", "")), scope)]
    for dataset in scoped_datasets:
        profile = dataset.get("profile", {})
        schema = profile.get("schema", []) or []
        if schema and all(not int(entry.get("missing", 0) or 0) for entry in schema):
            passed_checks.append(f"No missing or blank values detected in {_dataset_label(str(dataset.get('name', 'dataset')))}.")
        if schema and any(entry.get("logical_type") == "datetime" for entry in schema) and not any("date" in str(item).casefold() and "invalid" in str(item).casefold() for item in profile.get("invalid_or_suspicious_values", []) or []):
            passed_checks.append(f"Date-like fields in {_dataset_label(str(dataset.get('name', 'dataset')))} parsed without a reported malformed-date finding.")
        if not profile.get("categorical_inconsistencies"):
            passed_checks.append(f"No casing or whitespace category variants were detected in {_dataset_label(str(dataset.get('name', 'dataset')))}.")
    for relation in result.get("relationships", []) or []:
        if scope and not (_scope_matches(str(relation.get("source_table", "")), scope) or _scope_matches(str(relation.get("target_table", "")), scope)):
            continue
        if int(relation.get("orphan_rows", 0) or 0) == 0:
            target = str(relation.get("target_column", relation.get("source_column", "entity"))).replace("_id", "").replace("_key", "").replace("_", " ").strip()
            passed_checks.append(f"No populated foreign-key values point to unknown {target.title()} entities.")
    for issue in analytical_issues:
        if issue.issue_family == "duplicate_entity" and not issue.evidence.get("duplicate_versions_conflict"):
            passed_checks.append("Repeated entity rows contain no conflicting attributes.")
    passed_checks = list(dict.fromkeys(passed_checks))[:6]
    priority_actions = [f"Investigate {item.title.lower()}" if item.issue_family == "temporal_integrity" else item.recommended_action.rstrip(".") for item in analytical_issues if item.severity != "minor"]
    recommendation = "Recommended order: " + "; ".join(f"{index}. {action}" for index, action in enumerate(priority_actions[:3], 1)) + "." if priority_actions else "No remediation is indicated by the locally validated checks."
    response_model = {"headline": f"{(scope.title() if scope else 'Data')} data-quality assessment", "confirmed_issues": [issue_dict(item) for item in analytical_issues if item.severity != "minor"], "duplicate_reconciliation": {"included": any(item.issue_family == "duplicate_entity" for item in analytical_issues), "note": "Exact duplicate rows and duplicate identifiers are reconciled into one duplicate-entity issue while retaining their distinct count semantics."}, "minor_observations": [issue_dict(item) for item in analytical_issues if item.severity == "minor"], "passed_checks": passed_checks, "recommendation": recommendation}
    def structured_for(items: list[AnalyticalIssue], label: str, checks: list[str]) -> dict[str, Any]:
        confirmed_response = []
        for number, issue in enumerate((item for item in items if item.severity != "minor"), 1):
            example_rows = [dict(example.get("values", example)) if isinstance(example, dict) else {} for example in issue.examples[:MAX_LOCAL_EXAMPLES]]
            confirmed_response.append({"number": number, "title": issue.title, "severity": issue.severity, "summary": issue.summary_facts[0] if issue.summary_facts else "", "facts": list(issue.summary_facts[1:]), "examples": {"columns": list(dict.fromkeys(str(key) for example in example_rows for key in example)), "rows": example_rows}, "impact": issue.impact})
        minor_response = [{"area": issue.title, "finding": " ".join(issue.summary_facts), "impact": issue.impact} for issue in items if issue.severity == "minor"]
        actions = [f"Investigate {item.title.lower()}" if item.issue_family == "temporal_integrity" else item.recommended_action.rstrip(".") for item in items if item.severity != "minor"]
        return {"response_type": "analyst_quality_response", "intro": f"I found {len(confirmed_response)} {label.lower()} issue(s) worth addressing.", "confirmed_issues": confirmed_response, "minor_observations": minor_response, "passed_checks": checks, "recommendations": [action.rstrip(".") + "." for action in actions[:3]], "copy_text": ""}
    structured_response = structured_for(analytical_issues, scope or "Data", passed_checks)
    structured_responses = {"all": structured_response}
    for item_scope in ("customer", "product", "order", "region"):
        scoped_issues = consolidate_findings(result, item_scope)
        scoped_checks = [item for item in passed_checks if item_scope.casefold() in item.casefold() or item.casefold().startswith("no populated")]
        structured_responses[item_scope] = structured_for(scoped_issues, item_scope.title(), scoped_checks)
    lines = ["CONFIRMED ISSUES"]
    for number, issue in enumerate((item for item in analytical_issues if item.severity != "minor"), 1):
        lines.append(f"{number}. {issue.title} - {issue.severity.upper()}")
        lines.extend(f"- {fact}" for fact in issue.summary_facts)
        if issue.examples:
            lines.append("Examples: " + ". ".join("; ".join(f"{key}={value}" for key, value in example.items() if key != "source_row") for example in issue.examples[:MAX_LOCAL_EXAMPLES]))
        lines.append(f"Impact: {issue.impact}")
    lines.append("MINOR OBSERVATIONS")
    for issue in (item for item in analytical_issues if item.severity == "minor"):
        lines.append(f"- {issue.title}: " + " ".join(issue.summary_facts))
    for finding in groups["needs_review"]:
        if not any(finding.id in issue.source_finding_ids for issue in analytical_issues):
            lines.append(f"- {labels.get(finding.category, 'Review item')}: {human_evidence(finding)}")
    lines.append("PASSED CHECKS")
    if passed_checks:
        lines.extend(f"- {item}" for item in passed_checks)
    else:
        lines.append("- No blanket pass claimed; listed issues require review.")
    lines += ["RECOMMENDATION", f"- {response_model['recommendation']}"]
    full_answer = "\n".join(lines)
    structured_response["copy_text"] = full_answer
    def short_for(items: list[AnalyticalIssue], label: str) -> str:
        active = [item for item in items if item.severity != "minor"]
        minor = [item for item in items if item.severity == "minor"]
        short = [f"I found {len(active)} {label.casefold()} issue(s) worth addressing."]
        for number, item in enumerate(active[:5], 1):
            short.append(f"{number}. {item.title} - {item.severity.upper()}: " + " ".join(item.summary_facts) + f" Impact: {item.impact}")
        if minor:
            short.append("Minor observations: " + "; ".join(f"{item.title}: {' '.join(item.summary_facts)}" for item in minor[:3]))
        actions = [f"Investigate {item.title.lower()}" if item.issue_family == "temporal_integrity" else item.recommended_action.rstrip(".") for item in active[:3]]
        short.append("Recommendation: " + "; ".join(f"{index}. {action}" for index, action in enumerate(actions, 1)) + "." if actions else "No remediation is indicated by the locally validated checks.")
        return "\n".join(short)

    short_answers = {"all": short_for(analytical_issues, scope.title() if scope else "Data")}
    for item_scope in ("customer", "product", "order", "region"):
        short_answers[item_scope] = short_for(consolidate_findings(result, item_scope), item_scope.title())
    for item_scope, structured in structured_responses.items():
        if item_scope != "all":
            structured["copy_text"] = short_answers[item_scope]
    return {"findings": [finding.to_dict() for finding in findings], "analytical_issues": [issue.to_dict() for issue in analytical_issues], "answer": full_answer, "short_answer": short_answers[scope] if scope else short_answers["all"], "short_answers": short_answers, "scope": scope or "all", "analysis_scope": {"primary": scope or "all", "allowed_related": ["orders"] if scope == "customer" else [], "evidence_source": "local_profile_and_quality_evidence"}, "analyst_response_model": response_model, "structured_response": structured_response, "structured_responses": structured_responses, "answer_blueprint": build_answer_blueprint()}


def build_follow_up_context(plan: ChatAnalysisPlan, findings: list[AnalysisFinding]) -> dict[str, Any]:
    """Return only identifiers and descriptors suitable for conversation state."""
    selected = findings[0].id if findings else None
    return {
        "last_intent": plan.intent,
        "last_dataset_role": plan.dataset_scope[0] if plan.dataset_scope else None,
        "last_findings": [{"id": item.id, "category": item.category, "severity": item.severity} for item in findings],
        "last_selected_finding_id": selected,
    }


def resolve_follow_up(query: str, context: dict[str, Any]) -> dict[str, Any] | None:
    """Resolve references locally; never infer a finding from private text."""
    findings = context.get("last_findings", [])
    if not isinstance(findings, list) or not findings:
        return None
    tokens = _tokens(query)
    selected = context.get("last_selected_finding_id") or findings[0].get("id")
    if tokens & {"biggest", "most", "serious", "important"} and len(findings) > 1:
        rank = {"confirmed_issue": 3, "needs_review": 2, "warning": 2, "minor_observation": 1, "passed": 0}
        selected = max(findings, key=lambda item: rank.get(item.get("severity"), 0)).get("id")
    why = tokens & {"why", "matter", "matters", "important", "problem", "bad", "explain"}
    fix = tokens & {"fix", "fixes", "repair", "resolve", "do"}
    if not why and not fix:
        return None
    finding = next((item for item in findings if item.get("id") == selected), findings[0])
    action = FINDING_ACTION_REGISTRY.get(finding.get("category"), {"allowed_action": "review_only", "workflow": None})
    return {"kind": "fix" if fix and not why else "why", "finding_id": finding.get("id"), "category": finding.get("category"), "action": action}


_ALLOWED_PLACEHOLDERS = {"duplicate_rows", "duplicate_groups", "null_fk_count", "orphan_fk_count", "coverage"}


def render_local_template(template: str, evidence: dict[str, Any]) -> str:
    placeholders = set(re.findall(r"\{([a-zA-Z0-9_]+)\}", template))
    if not placeholders.issubset(_ALLOWED_PLACEHOLDERS):
        raise ValueError("Narrative template contains an unknown placeholder")
    return re.sub(r"\{([a-zA-Z0-9_]+)\}", lambda match: str(evidence.get(match.group(1), match.group(0))), template)
