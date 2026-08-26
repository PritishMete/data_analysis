from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from common.json_safe import to_json_safe
from query_history.models import QueryHistory

EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
PHONE_RE = re.compile(r"\b(?:\+?\d[\d\s().-]{7,}\d)\b")

_STRUCTURAL_KEYS = {
    "action",
    "candidate_state",
    "condition",
    "derived_columns",
    "else",
    "filters",
    "group_by",
    "intent",
    "keep_top_n_per_partition",
    "logic",
    "metrics",
    "order_by",
    "partition_by",
    "predicate_graph",
    "plan_source",
    "plan_template_id",
    "route",
    "semantic_roles",
    "steps",
    "then",
    "tool_sequence",
    "tool_graph",
    "type",
    "value",
    "value2",
    "window",
    "window_size",
}

_SENSITIVE_VALUE_KEYS = {
    "address",
    "addresses",
    "alias",
    "company",
    "companies",
    "customer",
    "customers",
    "details",
    "email",
    "emails",
    "error",
    "explanation",
    "filename",
    "filenames",
    "id",
    "ids",
    "message",
    "name",
    "names",
    "question",
    "query",
    "restaurant",
    "restaurants",
    "row",
    "rows",
    "sheet",
    "sheets",
    "sql",
    "text",
    "value",
    "value2",
    "values",
    "column",
    "columns",
    "group_by",
    "order_by",
    "filters",
    "metrics",
    "derived_columns",
}


def _env_value(*names: str, default: str | None = None) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value is not None and value != "":
            return value
    return default


def _env_bool(*names: str, default: bool = True) -> bool:
    value = _env_value(*names)
    if value is None:
        return default
    return str(value).strip().lower() not in {"0", "false", "no", "off"}


def _env_int(*names: str, default: int) -> int:
    value = _env_value(*names)
    if value is None:
        return default
    try:
        return int(value)
    except Exception:
        return default


def _env_float(*names: str, default: float) -> float:
    value = _env_value(*names)
    if value is None:
        return default
    try:
        return float(value)
    except Exception:
        return default


def _nested_value(payload: dict[str, Any] | list[Any] | None, *path: str) -> Any:
    current: Any = payload
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def _string_leaves(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
        return
    if isinstance(value, dict):
        for item in value.values():
            yield from _string_leaves(item)
        return
    if isinstance(value, (list, tuple, set)):
        for item in value:
            yield from _string_leaves(item)


def _sensitive_string_leaves(value: Any, *, parent_key: str | None = None) -> Iterable[str]:
    if isinstance(value, dict):
        for key, item in value.items():
            yield from _sensitive_string_leaves(item, parent_key=str(key).lower())
        return
    if isinstance(value, (list, tuple, set)):
        for item in value:
            yield from _sensitive_string_leaves(item, parent_key=parent_key)
        return
    if not isinstance(value, str):
        return
    lowered_key = (parent_key or "").lower()
    if lowered_key in _SENSITIVE_VALUE_KEYS:
        yield value
        return
    if EMAIL_RE.search(value) or PHONE_RE.search(value):
        yield value
        return
    if re.fullmatch(r"[A-Z]{2,}[A-Z0-9-]*\d[A-Z0-9-]*", value) or re.fullmatch(r"\d{7,}", value):
        yield value


def _safe_str(value: Any, *, default: str = "unknown") -> str:
    if value is None:
        return default
    text = str(value).strip()
    return text or default


def _safe_bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def _safe_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _safe_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _normalize_label(value: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "_", value.lower())
    text = re.sub(r"_+", "_", text).strip("_")
    return text or "unknown"


def _type_marker(value: Any) -> dict[str, Any]:
    if value is None:
        return {"kind": "null"}
    if isinstance(value, bool):
        return {"kind": "bool"}
    if isinstance(value, (int, float)):
        return {"kind": "number"}
    if isinstance(value, str):
        return {"kind": "string", "length": len(value)}
    if isinstance(value, dict):
        return {"kind": "dict", "size": len(value)}
    if isinstance(value, (list, tuple, set)):
        return {"kind": "list", "size": len(value)}
    return {"kind": type(value).__name__}


def _shape_value(value: Any) -> Any:
    if isinstance(value, dict):
        shaped: dict[str, Any] = {}
        for key in sorted(value):
            if key not in _STRUCTURAL_KEYS:
                continue
            shaped[key] = _shape_value(value[key])
        return shaped or _type_marker(value)
    if isinstance(value, list):
        return {"kind": "list", "size": len(value), "items": [_shape_value(item) for item in value[:3]]}
    if isinstance(value, tuple):
        return {"kind": "tuple", "size": len(value), "items": [_shape_value(item) for item in value[:3]]}
    return _type_marker(value)


def _shape_hash(payload: dict[str, Any]) -> str:
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    ).hexdigest()


@dataclass(slots=True)
class TrainingExportPolicy:
    minimum_quality: float = 0.95
    require_execution_success: bool = True
    require_critic_pass: bool = True
    require_result_validation: bool = True
    require_plan_completeness: bool = True
    require_privacy_pass: bool = True
    require_no_unresolved_ambiguity: bool = True
    require_no_critical_repair: bool = True
    allow_repaired_examples: bool = False
    max_examples_per_family: int = 1
    max_examples_per_intent: int = 250
    max_examples_per_tool_graph: int = 250
    train_split_ratio: float = 0.8
    validation_split_ratio: float = 0.1
    test_split_ratio: float = 0.1

    @classmethod
    def from_env(cls) -> "TrainingExportPolicy":
        return cls(
            minimum_quality=_env_float("MEMORY_ENGINE_EXPORT_MIN_QUALITY", default=0.95),
            require_execution_success=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_EXECUTION_SUCCESS", default=True),
            require_critic_pass=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_CRITIC_PASS", default=True),
            require_result_validation=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_RESULT_VALIDATION", default=True),
            require_plan_completeness=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_PLAN_COMPLETENESS", default=True),
            require_privacy_pass=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_PRIVACY_PASS", default=True),
            require_no_unresolved_ambiguity=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_NO_UNRESOLVED_AMBIGUITY", default=True),
            require_no_critical_repair=_env_bool("MEMORY_ENGINE_EXPORT_REQUIRE_NO_CRITICAL_REPAIR", default=True),
            allow_repaired_examples=_env_bool("MEMORY_ENGINE_EXPORT_ALLOW_REPAIRED_EXAMPLES", default=False),
            max_examples_per_family=max(1, _env_int("MEMORY_ENGINE_EXPORT_MAX_PER_FAMILY", default=1)),
            max_examples_per_intent=max(1, _env_int("MEMORY_ENGINE_EXPORT_MAX_PER_INTENT", default=250)),
            max_examples_per_tool_graph=max(1, _env_int("MEMORY_ENGINE_EXPORT_MAX_PER_TOOL_GRAPH", default=250)),
            train_split_ratio=max(0.0, _env_float("MEMORY_ENGINE_EXPORT_TRAIN_SPLIT", default=0.8)),
            validation_split_ratio=max(0.0, _env_float("MEMORY_ENGINE_EXPORT_VALIDATION_SPLIT", default=0.1)),
            test_split_ratio=max(0.0, _env_float("MEMORY_ENGINE_EXPORT_TEST_SPLIT", default=0.1)),
        )


@dataclass(slots=True)
class ExampleAssessment:
    entry: QueryHistory
    eligible: bool
    rejection_reasons: list[str] = field(default_factory=list)
    safe_record: dict[str, Any] | None = None
    structural_fingerprint: str | None = None
    split: str = "train"
    quality_score: float = 0.0
    intent: str = "unknown"
    tool_graph_key: str = "unknown"
    semantic_role_pattern: str = "unknown"
    predicate_complexity: int = 0
    step_count: int = 0
    plan_source: str = "unknown"


@dataclass(slots=True)
class TrainingExportBundle:
    records: list[dict[str, Any]]
    report: dict[str, Any]
    splits: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    persisted_paths: dict[str, str] = field(default_factory=dict)


def _collect_learning_context(entry: QueryHistory) -> dict[str, Any]:
    pipeline = entry.python_pipeline if isinstance(entry.python_pipeline, dict) else {}
    return _nested_value(pipeline, "learning") or _nested_value(pipeline, "metadata", "learning") or {}


def _extract_evidence(entry: QueryHistory) -> dict[str, Any]:
    learning = _collect_learning_context(entry)
    if not isinstance(learning, dict):
        learning = {}
    evidence = {
        "execution_success": entry.success if isinstance(entry.success, bool) else None,
        "critic_passed": _safe_bool(learning.get("critic_passed")),
        "result_validation_passed": _safe_bool(learning.get("result_validation_passed")),
        "plan_completeness_passed": _safe_bool(learning.get("plan_completeness_passed")),
        "privacy_validation_passed": _safe_bool(learning.get("privacy_validation_passed")),
        "no_unresolved_ambiguity": _safe_bool(learning.get("no_unresolved_ambiguity")),
        "no_critical_repair": _safe_bool(learning.get("no_critical_repair")),
        "repair_count": _safe_int(learning.get("repair_count")),
        "correction_state": learning.get("correction_state"),
        "quality_score": _safe_float(learning.get("quality_score")),
        "plan_source": _safe_str(learning.get("plan_source") or entry.planner_version, default="unknown"),
    }
    return evidence


def _extract_tool_graph(entry: QueryHistory) -> list[str]:
    pipeline = entry.python_pipeline
    if isinstance(pipeline, list):
        graph: list[str] = []
        for step in pipeline:
            if isinstance(step, dict):
                label = step.get("action") or step.get("op") or step.get("type") or step.get("name")
                if label:
                    graph.append(_normalize_label(str(label)))
        return list(dict.fromkeys(graph)) or ["sequence"]
    if not isinstance(pipeline, dict):
        return ["unknown"]

    graph: list[str] = []
    if pipeline.get("action"):
        graph.append(_normalize_label(str(pipeline["action"])))
    if pipeline.get("op"):
        graph.append(_normalize_label(str(pipeline["op"])))
    if pipeline.get("filters") or pipeline.get("where") or pipeline.get("conditions"):
        graph.append("filter_rows")
    if pipeline.get("group_by") or pipeline.get("metrics"):
        graph.append("aggregate")
    if pipeline.get("order_by"):
        graph.append("order_results")
    if pipeline.get("window"):
        graph.append("window")
    if pipeline.get("derived_columns"):
        graph.append("derive_columns")
    if pipeline.get("tool_sequence") and isinstance(pipeline["tool_sequence"], list):
        for step in pipeline["tool_sequence"]:
            if step is not None:
                graph.append(_normalize_label(str(step)))
    if not graph:
        graph.append("analysis")
    return list(dict.fromkeys(graph))


def _extract_semantic_roles(entry: QueryHistory) -> list[str]:
    pipeline = entry.python_pipeline
    roles: list[str] = []
    if isinstance(pipeline, list):
        if pipeline:
            roles.extend(["step"] * len(pipeline))
            return roles
        return ["unknown"]
    if not isinstance(pipeline, dict):
        return ["unknown"]

    group_by = pipeline.get("group_by")
    metrics = pipeline.get("metrics")
    filters = pipeline.get("filters")
    order_by = pipeline.get("order_by")
    derived_columns = pipeline.get("derived_columns")
    window = pipeline.get("window")

    if isinstance(group_by, list) and group_by:
        roles.extend(["dimension"] * len(group_by))
    if isinstance(metrics, list) and metrics:
        roles.extend(["measure"] * len(metrics))
    if isinstance(filters, list) and filters:
        roles.extend(["predicate"] * len(filters))
    if isinstance(order_by, list) and order_by:
        roles.extend(["ordering"] * len(order_by))
    if isinstance(derived_columns, list) and derived_columns:
        roles.extend(["label"] * len(derived_columns))
    if window:
        roles.append("window")
    if not roles:
        roles.append("unknown")
    return roles


def _extract_predicate_graph(entry: QueryHistory) -> dict[str, Any]:
    pipeline = entry.python_pipeline
    if not isinstance(pipeline, dict):
        return {"logical_structure": "SINGLE", "predicate_count": 0, "operators": []}

    filters = pipeline.get("filters") if isinstance(pipeline.get("filters"), list) else []
    derived_columns = pipeline.get("derived_columns") if isinstance(pipeline.get("derived_columns"), list) else []
    predicate_count = len(filters) + len(derived_columns)
    operators: list[str] = []
    for filter_spec in filters:
        if isinstance(filter_spec, dict):
            operator = filter_spec.get("operator")
            if operator:
                operators.append(_normalize_label(str(operator)))
    if pipeline.get("window") and isinstance(pipeline.get("window"), dict):
        window_type = pipeline["window"].get("type")
        if window_type:
            operators.append(_normalize_label(str(window_type)))
    if len(operators) == 0 and predicate_count:
        operators.append("predicate")
    return {
        "logical_structure": "AND" if predicate_count > 1 else "SINGLE",
        "predicate_count": predicate_count,
        "operators": list(dict.fromkeys(operators)),
    }


def _predicate_complexity(predicate_graph: dict[str, Any]) -> int:
    return int(predicate_graph.get("predicate_count") or len(predicate_graph.get("operators") or []))


def _family_fingerprint(
    *,
    intent: str,
    semantic_roles: list[str],
    predicate_graph: dict[str, Any],
    tool_graph: list[str],
    step_count: int,
    plan_source: str,
) -> str:
    payload = {
        "intent": intent,
        "semantic_roles": semantic_roles,
        "predicate_graph": predicate_graph,
        "tool_graph": tool_graph,
        "step_count": step_count,
        "plan_source": plan_source,
    }
    return _shape_hash(payload)


def _privacy_safe(record: dict[str, Any], entry: QueryHistory) -> tuple[bool, str | None]:
    serialized = json.dumps(record, sort_keys=True, separators=(",", ":"), default=str)
    lowered = serialized.lower()
    raw_query = _safe_str(entry.user_query, default="")
    if raw_query and raw_query.lower() in lowered:
        return False, "raw_query_leak"
    if entry.generated_sql:
        if entry.generated_sql.lower() in lowered:
            return False, "raw_sql_leak"
    for raw in _sensitive_string_leaves(entry.python_pipeline):
        if raw.lower() in lowered:
            return False, "pipeline_payload_leak"
    for raw in _sensitive_string_leaves(entry.visualization):
        if raw.lower() in lowered:
            return False, "visualization_payload_leak"
    if EMAIL_RE.search(serialized):
        return False, "email_like_payload"
    if PHONE_RE.search(serialized):
        return False, "phone_like_payload"
    return True, None


def _quality_score(entry: QueryHistory, evidence: dict[str, Any]) -> float | None:
    quality = evidence.get("quality_score")
    if isinstance(quality, (int, float)):
        quality = float(quality)
        return max(0.0, min(0.99, quality))
    return None


def _assessment_reasons(entry: QueryHistory, evidence: dict[str, Any], quality: float | None) -> list[str]:
    reasons: list[str] = []
    if evidence.get("execution_success") is not True:
        reasons.append("execution_failed")
    if evidence.get("critic_passed") is not True:
        reasons.append("critic_missing" if evidence.get("critic_passed") is None else "critic_failed")
    if evidence.get("result_validation_passed") is not True:
        reasons.append("result_validation_missing" if evidence.get("result_validation_passed") is None else "result_validation_failed")
    if evidence.get("plan_completeness_passed") is not True:
        reasons.append("plan_completeness_missing" if evidence.get("plan_completeness_passed") is None else "plan_completeness_failed")
    if evidence.get("privacy_validation_passed") is not True:
        reasons.append("privacy_validation_missing" if evidence.get("privacy_validation_passed") is None else "privacy_validation_failed")
    if evidence.get("no_unresolved_ambiguity") is not True:
        reasons.append("ambiguity_missing" if evidence.get("no_unresolved_ambiguity") is None else "unresolved_ambiguity")
    if evidence.get("no_critical_repair") is not True:
        reasons.append("repair_present" if evidence.get("no_critical_repair") is False else "repair_missing")
    repair_count = evidence.get("repair_count")
    if isinstance(repair_count, int) and repair_count > 0:
        reasons.append("repair_present")
    correction_state = _safe_str(evidence.get("correction_state"), default="").lower()
    if correction_state and correction_state not in {"validated", "trusted"}:
        reasons.append("correction_not_trusted")
    if quality is None:
        reasons.append("quality_missing")
    elif quality < 0.95:
        reasons.append("quality_below_threshold")
    return list(dict.fromkeys(reasons))


def assess_entry(entry: QueryHistory, policy: TrainingExportPolicy) -> ExampleAssessment:
    evidence = _extract_evidence(entry)
    intent = _safe_str(entry.intent, default="unknown")
    tool_graph = _extract_tool_graph(entry)
    semantic_roles = _extract_semantic_roles(entry)
    predicate_graph = _extract_predicate_graph(entry)
    step_count = 0
    if isinstance(entry.python_pipeline, list):
        step_count = len(entry.python_pipeline)
    if isinstance(entry.python_pipeline, dict):
        step_count = len(
            [
                key
                for key in ("action", "filters", "group_by", "metrics", "order_by", "window", "derived_columns", "tool_sequence")
                if entry.python_pipeline.get(key)
            ]
        )
    plan_source = _safe_str(evidence.get("plan_source"), default="unknown")
    quality = _quality_score(entry, evidence)
    record = {
        "input": {
            "intent": intent,
            "semantic_roles": semantic_roles,
            "predicate_graph": predicate_graph,
            "step_count": step_count,
        },
        "output": {
            "tool_graph": tool_graph,
        },
        "metadata": {
            "quality": quality,
            "plan_source": plan_source,
            "execution_success": evidence.get("execution_success"),
            "critic_passed": evidence.get("critic_passed"),
            "result_validation_passed": evidence.get("result_validation_passed"),
            "plan_completeness_passed": evidence.get("plan_completeness_passed"),
            "privacy_validation_passed": evidence.get("privacy_validation_passed"),
            "no_unresolved_ambiguity": evidence.get("no_unresolved_ambiguity"),
            "no_critical_repair": evidence.get("no_critical_repair"),
            "repair_count": evidence.get("repair_count"),
            "correction_state": evidence.get("correction_state"),
            "planner_version": entry.planner_version,
        },
    }
    safe_record = to_json_safe(record)
    privacy_ok, privacy_reason = _privacy_safe(safe_record, entry)
    reasons = _assessment_reasons(entry, evidence, quality)
    if not privacy_ok and privacy_reason:
        reasons.append(privacy_reason)
    fingerprint = _family_fingerprint(
        intent=intent,
        semantic_roles=semantic_roles,
        predicate_graph=predicate_graph,
        tool_graph=tool_graph,
        step_count=step_count,
        plan_source=plan_source,
    )
    return ExampleAssessment(
        entry=entry,
        eligible=not reasons,
        rejection_reasons=reasons,
        safe_record=safe_record if not reasons else None,
        structural_fingerprint=fingerprint,
        split=_assign_split(fingerprint, policy),
        quality_score=float(quality or 0.0),
        intent=intent,
        tool_graph_key="|".join(tool_graph),
        semantic_role_pattern="|".join(semantic_roles),
        predicate_complexity=_predicate_complexity(predicate_graph),
        step_count=step_count,
        plan_source=plan_source,
    )


def _assign_split(fingerprint: str, policy: TrainingExportPolicy) -> str:
    bucket = int(fingerprint[:8], 16) % 10
    train_cutoff = int(round(policy.train_split_ratio * 10))
    validation_cutoff = train_cutoff + int(round(policy.validation_split_ratio * 10))
    if bucket < train_cutoff:
        return "train"
    if bucket < validation_cutoff:
        return "validation"
    return "test"


def _flatten_record(record: dict[str, Any]) -> dict[str, Any]:
    flat: dict[str, Any] = {}

    def _walk(prefix: str, value: Any) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                _walk(f"{prefix}.{key}" if prefix else key, child)
            return
        if isinstance(value, list):
            flat[prefix] = json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)
            return
        flat[prefix] = value

    _walk("", record)
    return flat


def _split_counts(records: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"train": 0, "validation": 0, "test": 0}
    for record in records:
        split = str(record.get("metadata", {}).get("split") or "train")
        if split not in counts:
            split = "train"
        counts[split] += 1
    return counts


def _distribution(records: list[dict[str, Any]], path: tuple[str, ...]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for record in records:
        current: Any = record
        for key in path:
            if not isinstance(current, dict):
                current = None
                break
            current = current.get(key)
        if isinstance(current, list):
            key = "|".join(str(item) for item in current) or "unknown"
        else:
            key = _safe_str(current, default="unknown")
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items(), key=lambda item: (-item[1], item[0])))


def build_report(
    assessments: list[ExampleAssessment],
    selected_records: list[dict[str, Any]],
    *,
    policy: TrainingExportPolicy,
    duplicates_removed: int,
) -> dict[str, Any]:
    report = {
        "total_experiences_inspected": len(assessments),
        "eligible_examples": len(selected_records),
        "rejected_examples": len(assessments) - len(selected_records),
        "duplicates_removed": duplicates_removed,
        "rejection_reasons": {},
        "intent_distribution": _distribution(selected_records, ("input", "intent")),
        "tool_graph_distribution": _distribution(selected_records, ("output", "tool_graph")),
        "semantic_role_distribution": _distribution(selected_records, ("input", "semantic_roles")),
        "plan_source_distribution": _distribution(selected_records, ("metadata", "plan_source")),
        "number_of_steps_distribution": _distribution(selected_records, ("input", "step_count")),
        "predicate_complexity_distribution": _distribution(selected_records, ("input", "predicate_graph", "predicate_count")),
        "average_quality": round(
            sum(float(record.get("metadata", {}).get("quality") or 0.0) for record in selected_records) / len(selected_records),
            4,
        )
        if selected_records
        else 0.0,
        "train_count": 0,
        "validation_count": 0,
        "test_count": 0,
        "split_distribution": _split_counts(selected_records),
        "policy": {
            "minimum_quality": policy.minimum_quality,
            "require_execution_success": policy.require_execution_success,
            "require_critic_pass": policy.require_critic_pass,
            "require_result_validation": policy.require_result_validation,
            "require_plan_completeness": policy.require_plan_completeness,
            "require_privacy_pass": policy.require_privacy_pass,
            "require_no_unresolved_ambiguity": policy.require_no_unresolved_ambiguity,
            "require_no_critical_repair": policy.require_no_critical_repair,
            "allow_repaired_examples": policy.allow_repaired_examples,
            "max_examples_per_family": policy.max_examples_per_family,
            "max_examples_per_intent": policy.max_examples_per_intent,
            "max_examples_per_tool_graph": policy.max_examples_per_tool_graph,
            "train_split_ratio": policy.train_split_ratio,
            "validation_split_ratio": policy.validation_split_ratio,
            "test_split_ratio": policy.test_split_ratio,
        },
    }
    report["train_count"] = report["split_distribution"]["train"]
    report["validation_count"] = report["split_distribution"]["validation"]
    report["test_count"] = report["split_distribution"]["test"]

    rejection_reasons: dict[str, int] = {}
    for assessment in assessments:
        if assessment.safe_record is not None:
            continue
        for reason in assessment.rejection_reasons:
            rejection_reasons[reason] = rejection_reasons.get(reason, 0) + 1
    report["rejection_reasons"] = dict(sorted(rejection_reasons.items(), key=lambda item: (-item[1], item[0])))
    return report


def persist_bundle(bundle: TrainingExportBundle, *, output_dir: Path | None = None) -> TrainingExportBundle:
    training_dir = output_dir or Path(__file__).resolve().parents[1] / "runtime" / "training"
    training_dir.mkdir(parents=True, exist_ok=True)

    persisted: dict[str, str] = {}
    for split, records in bundle.splits.items():
        split_path = training_dir / f"{split}.jsonl"
        split_path.write_text(
            "\n".join(json.dumps(record, ensure_ascii=False, sort_keys=True, default=str) for record in records)
            + ("\n" if records else ""),
            encoding="utf-8",
        )
        persisted[f"{split}.jsonl"] = str(split_path)

    report_path = training_dir / "dataset_report.json"
    report_path.write_text(json.dumps(bundle.report, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    persisted["dataset_report.json"] = str(report_path)
    bundle.persisted_paths = persisted
    return bundle
