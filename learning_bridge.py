from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from threading import Lock
from typing import Any

import pandas as pd

from ai_privacy import validate_metadata_planner_payload
from common.json_safe import to_json_safe
from privacy_context import dataframe_profile, sanitize_user_text, safe_columns, strict_enabled

logger = logging.getLogger(__name__)


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


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


def _env_float(*names: str, default: float) -> float:
    value = _env_value(*names)
    if value is None:
        return default
    try:
        return float(value)
    except Exception:
        return default


def _env_int(*names: str, default: int) -> int:
    value = _env_value(*names)
    if value is None:
        return default
    try:
        return int(value)
    except Exception:
        return default


def _normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", (text or "").lower())).strip()


def _infer_intent(user_text: str) -> str:
    text = _normalize_text(user_text)
    if any(token in text for token in {"filter", "show", "find", "where", "with", "having", "rows", "records"}):
        return "filter"
    if any(token in text for token in {"top", "bottom", "rank", "highest", "lowest", "average", "avg", "sum", "count", "group by"}):
        return "aggregate"
    if any(token in text for token in {"trend", "over time", "time series", "month", "week", "year"}):
        return "trend"
    if any(token in text for token in {"compare", "versus", "vs", "between"}):
        return "compare"
    if any(token in text for token in {"clean", "rename", "dedupe", "deduplicate", "normalize", "bucket", "categorize", "classify"}):
        return "operation"
    if any(token in text for token in {"sentiment", "review", "reviews", "rating", "restaurant"}):
        return "sentiment"
    return "analysis"


def _query_features_payload(intent: str, fields: list[dict[str, Any]]) -> dict[str, Any]:
    semantic_roles = [str(field.get("semantic_role") or "unknown") for field in fields]
    operator_hints: list[str] = []
    role_text = " ".join(semantic_roles)
    if "boolean" in role_text:
        operator_hints.append("equals_true")
    if any(role in {"numeric_metric", "rating_metric", "currency_metric", "percentage"} for role in semantic_roles):
        operator_hints.extend(["greater_than", "less_than"])
    if intent in {"aggregate", "trend", "compare"}:
        operator_hints.extend(["group_by", "order_by"])
    if intent == "filter":
        operator_hints.append("contains")
    logical_structure = "AND" if len([role for role in semantic_roles if role != "unknown"]) > 1 else "SINGLE"
    return {
        "predicate_count": max(1, len([role for role in semantic_roles if role != "unknown"])),
        "logical_structure": logical_structure,
        "semantic_roles": semantic_roles,
        "operators": list(dict.fromkeys(operator_hints)),
    }


@dataclass(slots=True)
class LearningBridgeConfig:
    base_url: str = "http://127.0.0.1:8001"
    enabled: bool = True
    timeout_seconds: float = 2.0
    min_sql_confidence: float = 0.82
    token: str = ""
    circuit_failure_threshold: int = 3
    circuit_cooldown_seconds: float = 30.0

    @classmethod
    def from_env(cls) -> "LearningBridgeConfig":
        return cls(
            base_url=(
                _env_value("LEARNING_SERVICE_URL", "INSIGHT_LEARNING_URL", default="http://127.0.0.1:8001") or
                "http://127.0.0.1:8001"
            ).rstrip("/"),
            enabled=_env_bool("LEARNING_SERVICE_ENABLED", "INSIGHT_LEARNING_ENABLED", default=True),
            timeout_seconds=_env_float(
                "LEARNING_SERVICE_TIMEOUT_SECONDS",
                "LEARNING_PLAN_TIMEOUT_SECONDS",
                "INSIGHT_LEARNING_TIMEOUT_SECONDS",
                default=2.0,
            ),
            min_sql_confidence=_env_float(
                "LEARNING_MIN_SQL_CONFIDENCE",
                "INSIGHT_LEARNING_MIN_SQL_CONFIDENCE",
                default=0.82,
            ),
            token=str(
                _env_value("LEARNING_SERVICE_TOKEN", "INSIGHT_LEARNING_TOKEN", default="") or ""
            ),
            circuit_failure_threshold=max(
                1,
                _env_int("LEARNING_CIRCUIT_FAILURE_THRESHOLD", "INSIGHT_LEARNING_CIRCUIT_FAILURE_THRESHOLD", default=3),
            ),
            circuit_cooldown_seconds=max(
                0.0,
                _env_float("LEARNING_CIRCUIT_COOLDOWN_SECONDS", "INSIGHT_LEARNING_CIRCUIT_COOLDOWN_SECONDS", default=30.0),
            ),
        )


@dataclass(slots=True)
class SafeFieldAlias:
    id: str
    semantic_role: str
    dtype: str

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "semantic_role": self.semantic_role, "dtype": self.dtype}


@dataclass(slots=True)
class SafeQueryAbstraction:
    text: str
    intent: str
    query_features: dict[str, Any]
    fields: list[SafeFieldAlias]
    field_map: dict[str, str]
    reverse_field_map: dict[str, str]
    available_sheets: list[str] = field(default_factory=list)
    dataset_semantic_signature: str | None = None
    anonymized_text: str = ""

    def to_plan_request(self) -> dict[str, Any]:
        return {
            "intent": self.intent,
            "query_features": self.query_features,
            "dataset_profile": {"fields": [field.to_dict() for field in self.fields]},
        }

    def to_event_payload(self) -> dict[str, Any]:
        return {
            "intent": self.intent,
            "query_features": self.query_features,
            "dataset_profile": {"fields": [field.to_dict() for field in self.fields]},
            "safe_query_abstraction": {
                "available_columns": [field.id for field in self.fields],
                "available_sheet_count": len(self.available_sheets),
                "dataset_semantic_signature": self.dataset_semantic_signature,
            },
        }


@dataclass(slots=True)
class LearningPlanResult:
    accepted: bool
    confidence: float
    plan_source: str
    route: str
    plan: dict[str, Any] | None
    skill_id: str | None
    plan_template_id: str | None
    message: str = ""
    raw_response: dict[str, Any] = field(default_factory=dict)
    reverse_field_map: dict[str, str] = field(default_factory=dict)

    def remap_plan(self) -> dict[str, Any] | None:
        if self.plan is None:
            return None
        return _remap_plan(self.plan, self.reverse_field_map)


@dataclass(slots=True)
class LearningEvent:
    schema_version: int
    event_id: str
    intent: str
    query_features: dict[str, Any]
    dataset_profile: dict[str, Any] | None = None
    tool_graph: list[str] = field(default_factory=list)
    plan: dict[str, Any] = field(default_factory=dict)
    execution: dict[str, Any] = field(default_factory=dict)
    validation: dict[str, Any] = field(default_factory=dict)
    quality_score: float = 0.0
    route: str | None = None
    plan_source: str | None = None
    skill_id: str | None = None
    plan_template_id: str | None = None
    dataset_semantic_signature: str | None = None
    critic_passed: bool | None = None
    result_validation_passed: bool | None = None
    plan_completeness_passed: bool | None = None
    privacy_validation_passed: bool | None = None
    no_unresolved_ambiguity: bool | None = None
    no_critical_repair: bool | None = None
    repair_count: int | None = None
    correction_state: str | None = None
    safe_query_abstraction: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return to_json_safe(asdict(self))


def _remap_plan(plan: dict[str, Any], reverse_field_map: dict[str, str]) -> dict[str, Any]:
    if not reverse_field_map:
        return dict(plan)

    def _remap(value: Any) -> Any:
        if isinstance(value, dict):
            return {(_remap(k) if isinstance(k, str) else k): _remap(v) for k, v in value.items()}
        if isinstance(value, list):
            return [_remap(item) for item in value]
        if isinstance(value, tuple):
            return tuple(_remap(item) for item in value)
        if isinstance(value, str):
            return reverse_field_map.get(value, value)
        return value

    return _remap(plan)


def _nested_value(payload: dict[str, Any] | None, *path: str) -> Any:
    current: Any = payload
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def _as_bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _as_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _pick_bool(*values: Any) -> bool | None:
    for value in values:
        if isinstance(value, bool):
            return value
    return None


def _pick_int(*values: Any) -> int | None:
    for value in values:
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
    return None


def _safe_tool_graph(route: str | None, plan: dict[str, Any] | None) -> list[str]:
    if isinstance(plan, dict):
        tool_graph = plan.get("tool_sequence")
        if isinstance(tool_graph, list) and tool_graph:
            return [str(step) for step in tool_graph if step is not None]
        if isinstance(tool_graph, tuple) and tool_graph:
            return [str(step) for step in tool_graph if step is not None]
    route = str(route or "").lower()
    if route == "sql":
        inferred = ["sql.query"]
        if isinstance(plan, dict):
            if plan.get("filters"):
                inferred.append("sql.filter")
            if plan.get("group_by") or plan.get("metrics"):
                inferred.append("sql.group_by")
            if plan.get("window"):
                inferred.append("sql.window")
        return list(dict.fromkeys(inferred))
    if route == "sentiment":
        return ["sentiment.analyze"]
    if route == "operation":
        return ["operation.transform"]
    return ["analysis.route"]


def _safe_plan_abstraction(
    *,
    abstraction: SafeQueryAbstraction,
    result: dict[str, Any],
    route: str,
    tool_graph: list[str],
    plan_source: str | None,
    plan_template_id: str | None,
    skill_id: str | None,
) -> dict[str, Any]:
    return {
        "intent": abstraction.intent,
        "semantic_roles": [field.semantic_role for field in abstraction.fields],
        "predicate_graph": {
            "logical_structure": abstraction.query_features.get("logical_structure", "SINGLE"),
            "predicate_count": abstraction.query_features.get("predicate_count", len(abstraction.fields)),
            "operators": list(abstraction.query_features.get("operators") or []),
        },
        "tool_graph": list(tool_graph),
        "route": route,
        "plan_source": plan_source,
        "plan_template_id": plan_template_id,
        "skill_id": skill_id,
        "quality_score": _as_float(result.get("confidence")) or 0.0,
    }


def build_safe_query_abstraction(
    user_text: str,
    df: pd.DataFrame,
    available_sheets: list[str] | None = None,
) -> SafeQueryAbstraction:
    available_sheets = [str(sheet) for sheet in (available_sheets or [])]
    safe_text, _, safe_sheet_list = validate_metadata_planner_payload(
        {
            "text": user_text,
            "available_columns": [str(column) for column in df.columns],
            "available_sheets": available_sheets,
        },
        allow_sheets=True,
    )
    profile = dataframe_profile(df, include_samples=False)
    fields: list[SafeFieldAlias] = []
    for column in profile.get("columns", []):
        if not isinstance(column, dict):
            continue
        fields.append(
            SafeFieldAlias(
                id=str(column.get("column_id") or f"FIELD_{len(fields) + 1:02d}"),
                semantic_role=str(column.get("role") or "unknown"),
                dtype=str(column.get("dtype") or "unknown"),
            )
        )
    if not fields:
        safe_ids, forward_map, reverse_map = safe_columns(df.columns)
        fields = [SafeFieldAlias(id=safe_id, semantic_role="unknown", dtype="unknown") for safe_id in safe_ids]
    else:
        forward_map = {str(column): field.id for column, field in zip(df.columns, fields)}
        reverse_map = {field.id: str(column) for column, field in zip(df.columns, fields)}

    intent = _infer_intent(user_text)
    query_features = _query_features_payload(intent, [field.to_dict() for field in fields])
    anonymized_text = sanitize_user_text(safe_text, columns=list(df.columns), df=df)
    dataset_semantic_signature = None
    if fields:
        dataset_semantic_signature = uuid.uuid5(
            uuid.NAMESPACE_URL,
            json.dumps({"fields": [field.to_dict() for field in fields]}, sort_keys=True),
        ).hex

    return SafeQueryAbstraction(
        text=str(user_text or ""),
        intent=intent,
        query_features=query_features,
        fields=fields,
        field_map=forward_map,
        reverse_field_map=reverse_map,
        available_sheets=safe_sheet_list,
        dataset_semantic_signature=dataset_semantic_signature,
        anonymized_text=anonymized_text,
    )


def build_learning_event(
    *,
    user_text: str,
    result: dict[str, Any],
    abstraction: SafeQueryAbstraction,
) -> LearningEvent:
    route = str(result.get("route") or "operation")
    plan = dict(result.get("plan") or result.get("operation") or {})
    success = bool(result.get("success"))
    validation = {
        "success": success,
        "warnings": list(result.get("warnings") or []),
        "errors": list(result.get("errors") or []),
    }
    execution: dict[str, Any] = {
        "success": success,
        "route": route,
        "result_kind": "table" if route == "sql" and result.get("result") else "operation" if route == "operation" else "sentiment" if route == "sentiment" else "error",
        "row_count": None,
        "column_count": None,
        "sql_present": bool(result.get("sql")),
    }
    if route == "sql" and isinstance(result.get("result"), dict):
        execution["row_count"] = int(result["result"].get("row_count") or len(result["result"].get("rows") or []))
        execution["column_count"] = int(len(result["result"].get("columns") or []))
    elif route == "operation" and isinstance(result.get("operation"), dict):
        operation = result["operation"]
        data = operation.get("data") if isinstance(operation, dict) else None
        if isinstance(data, dict):
            execution["row_count"] = int(data.get("row_count") or len(data.get("rows") or []))
            execution["column_count"] = int(data.get("column_count") or len(data.get("columns") or []))

    quality_score = 0.18
    if success:
        quality_score = 0.92 if route == "sql" else 0.88 if route == "operation" else 0.8
        if execution.get("row_count") in {0, None}:
            quality_score -= 0.04
        if result.get("warnings"):
            quality_score -= 0.03

    return LearningEvent(
        schema_version=1,
        event_id=uuid.uuid5(
            uuid.NAMESPACE_URL,
            json.dumps(
                {
                    "text": user_text,
                    "route": route,
                    "plan": plan,
                    "success": success,
                    "quality_score": quality_score,
                },
                sort_keys=True,
                default=str,
            ),
        ).hex,
        source="teacher",
        timestamp=_utcnow_iso(),
        intent=abstraction.intent,
        query_features=abstraction.query_features,
        dataset_profile={"fields": [field.to_dict() for field in abstraction.fields]},
        plan=plan,
        execution=execution,
        validation=validation,
        quality_score=round(max(0.0, min(0.99, quality_score)), 4),
        route=route,
        plan_source=str(result.get("plan_source") or result.get("learning", {}).get("plan_source") or "teacher_execution"),
        skill_id=result.get("skill_id"),
        plan_template_id=result.get("plan_template_id"),
        dataset_semantic_signature=abstraction.dataset_semantic_signature,
        safe_query_abstraction={
            "text": abstraction.anonymized_text or abstraction.text,
            "available_columns": [field.id for field in abstraction.fields],
            "available_sheets": list(abstraction.available_sheets),
            "dataset_semantic_signature": abstraction.dataset_semantic_signature,
        },
    )


def build_learning_event(
    *,
    user_text: str,
    result: dict[str, Any],
    abstraction: SafeQueryAbstraction,
) -> LearningEvent:
    route = str(result.get("route") or "operation")
    raw_plan = result.get("plan")
    if not isinstance(raw_plan, dict):
        raw_plan = result.get("operation") if isinstance(result.get("operation"), dict) else {}

    plan_source = str(
        result.get("plan_source")
        or _nested_value(result, "metadata", "learning", "plan_source")
        or "teacher_execution"
    )
    plan_template_id = result.get("plan_template_id") or _nested_value(result, "metadata", "learning", "plan_template_id")
    skill_id = result.get("skill_id") or _nested_value(result, "metadata", "learning", "skill_id")
    tool_graph = _safe_tool_graph(route, raw_plan if isinstance(raw_plan, dict) else None)

    success = _pick_bool(result.get("success"))
    if success is None:
        success = False

    execution: dict[str, Any] = {
        "success": success,
        "route": route,
        "result_kind": (
            "table"
            if route == "sql"
            else "sentiment"
            if route == "sentiment"
            else "operation"
            if route == "operation"
            else "error"
        ),
        "row_count": None,
        "column_count": None,
        "sql_present": bool(result.get("sql")),
    }
    sql_result = result.get("result")
    if route == "sql" and isinstance(sql_result, dict):
        row_count = sql_result.get("row_count")
        if row_count is None and isinstance(sql_result.get("rows"), list):
            row_count = len(sql_result.get("rows") or [])
        execution["row_count"] = _as_int(row_count)
        execution["column_count"] = _as_int(len(sql_result.get("columns") or []))
    elif route == "operation":
        op_result = result.get("operation") if isinstance(result.get("operation"), dict) else None
        op_data = op_result.get("data") if isinstance(op_result, dict) else None
        if isinstance(op_data, dict):
            row_count = op_data.get("row_count")
            if row_count is None and isinstance(op_data.get("rows"), list):
                row_count = len(op_data.get("rows") or [])
            execution["row_count"] = _as_int(row_count)
            execution["column_count"] = _as_int(len(op_data.get("columns") or []))

    validation = {
        "success": success,
        "warning_count": len(result.get("warnings") or []),
        "error_count": len(result.get("errors") or []),
        "has_message": bool(result.get("message")),
        "route": route,
    }

    critic_passed = _pick_bool(
        result.get("critic_passed"),
        _nested_value(result, "metadata", "learning", "critic_passed"),
        _nested_value(result, "metadata", "critic_status", "passed"),
    )
    result_validation_passed = _pick_bool(
        result.get("result_validation_passed"),
        _nested_value(result, "metadata", "learning", "result_validation_passed"),
    )
    plan_completeness_passed = _pick_bool(
        result.get("plan_completeness_passed"),
        _nested_value(result, "metadata", "learning", "plan_completeness_passed"),
    )
    privacy_validation_passed = _pick_bool(
        result.get("privacy_validation_passed"),
        _nested_value(result, "metadata", "learning", "privacy_validation_passed"),
    )
    no_unresolved_ambiguity = _pick_bool(
        result.get("no_unresolved_ambiguity"),
        _nested_value(result, "metadata", "learning", "no_unresolved_ambiguity"),
    )
    no_critical_repair = _pick_bool(
        result.get("no_critical_repair"),
        _nested_value(result, "metadata", "learning", "no_critical_repair"),
    )
    repair_count = _pick_int(result.get("repair_count"), _nested_value(result, "metadata", "learning", "repair_count"))
    correction_state = result.get("correction_state") or _nested_value(result, "metadata", "learning", "correction_state")

    quality_score = _as_float(result.get("quality_score"))
    if quality_score is None:
        quality_score = _as_float(result.get("confidence")) or 0.0
    quality_score = round(max(0.0, min(0.99, float(quality_score))), 4)

    safe_plan = _safe_plan_abstraction(
        abstraction=abstraction,
        result=result,
        route=route,
        tool_graph=tool_graph,
        plan_source=plan_source,
        plan_template_id=str(plan_template_id) if plan_template_id is not None else None,
        skill_id=str(skill_id) if skill_id is not None else None,
    )

    event_id_payload = {
        "intent": abstraction.intent,
        "query_features": abstraction.query_features,
        "dataset_semantic_signature": abstraction.dataset_semantic_signature,
        "route": route,
        "tool_graph": tool_graph,
        "plan_source": plan_source,
        "plan_template_id": str(plan_template_id) if plan_template_id is not None else None,
        "skill_id": str(skill_id) if skill_id is not None else None,
        "quality_score": quality_score,
        "execution": execution,
        "validation": validation,
        "critic_passed": critic_passed,
        "result_validation_passed": result_validation_passed,
        "plan_completeness_passed": plan_completeness_passed,
        "privacy_validation_passed": privacy_validation_passed,
        "no_unresolved_ambiguity": no_unresolved_ambiguity,
        "no_critical_repair": no_critical_repair,
        "repair_count": repair_count,
        "correction_state": correction_state,
        "plan": safe_plan,
    }

    return LearningEvent(
        schema_version=1,
        event_id=uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(event_id_payload, sort_keys=True, default=str)).hex,
        intent=abstraction.intent,
        query_features=abstraction.query_features,
        dataset_profile={"fields": [field.to_dict() for field in abstraction.fields]},
        tool_graph=tool_graph,
        plan=safe_plan,
        execution=execution,
        validation=validation,
        quality_score=quality_score,
        route=route,
        plan_source=plan_source,
        skill_id=str(skill_id) if skill_id is not None else None,
        plan_template_id=str(plan_template_id) if plan_template_id is not None else None,
        dataset_semantic_signature=abstraction.dataset_semantic_signature,
        critic_passed=critic_passed,
        result_validation_passed=result_validation_passed,
        plan_completeness_passed=plan_completeness_passed,
        privacy_validation_passed=privacy_validation_passed,
        no_unresolved_ambiguity=no_unresolved_ambiguity,
        no_critical_repair=no_critical_repair,
        repair_count=repair_count,
        correction_state=correction_state if isinstance(correction_state, str) else None,
        safe_query_abstraction={
            "available_columns": [field.id for field in abstraction.fields],
            "available_sheet_count": len(abstraction.available_sheets),
            "dataset_semantic_signature": abstraction.dataset_semantic_signature,
        },
    )


class LearningBridgeClient:
    def __init__(self, config: LearningBridgeConfig | None = None) -> None:
        self.config = config or LearningBridgeConfig.from_env()
        self.base_url = self.config.base_url
        self.enabled = self.config.enabled
        self.timeout_seconds = self.config.timeout_seconds
        self.min_sql_confidence = self.config.min_sql_confidence
        self.token = self.config.token
        self.circuit_failure_threshold = self.config.circuit_failure_threshold
        self.circuit_cooldown_seconds = self.config.circuit_cooldown_seconds
        self._lock = Lock()
        self._failure_count = 0
        self._circuit_open_until = 0.0

    def _now(self) -> float:
        return time.monotonic()

    def _circuit_open(self) -> bool:
        with self._lock:
            if self._circuit_open_until <= 0:
                return False
            if self._now() >= self._circuit_open_until:
                self._failure_count = 0
                self._circuit_open_until = 0.0
                return False
            return True

    def _register_success(self) -> None:
        with self._lock:
            self._failure_count = 0
            self._circuit_open_until = 0.0

    def _register_failure(self) -> None:
        with self._lock:
            self._failure_count += 1
            if self._failure_count >= self.circuit_failure_threshold:
                self._circuit_open_until = self._now() + self.circuit_cooldown_seconds

    def _request_headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _post_json(self, path: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        if not self.enabled or self._circuit_open():
            return None
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            method="POST",
            headers=self._request_headers(),
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                response_body = response.read().decode("utf-8")
                parsed = json.loads(response_body) if response_body else {}
                if isinstance(parsed, dict) and parsed:
                    self._register_success()
                    return parsed
                self._register_failure()
                return None
        except urllib.error.HTTPError as exc:
            self._register_failure()
            try:
                logger.warning("Insight Learning HTTP %s on %s: %s", exc.code, path, exc.read().decode("utf-8", errors="ignore"))
            except Exception:
                logger.warning("Insight Learning HTTP %s on %s", exc.code, path)
        except json.JSONDecodeError as exc:
            self._register_failure()
            logger.debug("Insight Learning response decode failed for %s: %s", path, exc)
        except Exception as exc:
            self._register_failure()
            logger.debug("Insight Learning bridge call failed for %s: %s", path, exc)
        return None

    async def plan(self, abstraction: SafeQueryAbstraction) -> LearningPlanResult | None:
        response = await asyncio.to_thread(self._post_json, "/v1/plan", abstraction.to_plan_request())
        if not response or not isinstance(response, dict):
            return None
        plan = response.get("plan")
        if not isinstance(plan, dict) or not plan:
            self._register_failure()
            return None
        route = "operation" if str(plan.get("action") or "").lower() == "categorize" else "sql"
        confidence = _as_float(response.get("confidence")) or 0.0
        plan_source = str(response.get("plan_source") or "experience_transfer")
        accepted = route == "sql" and confidence >= self.min_sql_confidence and plan_source != "deterministic_fallback"
        critic_notes: list[str] = []
        critic_status = response.get("critic_status")
        if isinstance(critic_status, dict):
            critic_notes = [str(note) for note in critic_status.get("notes") or [] if note]
        return LearningPlanResult(
            accepted=accepted,
            confidence=confidence,
            plan_source=plan_source,
            route=route,
            plan=plan,
            skill_id=response.get("skill_id"),
            plan_template_id=response.get("plan_template_id"),
            message=critic_notes[0] if critic_notes else "",
            raw_response=response,
            reverse_field_map=abstraction.reverse_field_map,
        )

    async def ingest(self, event: LearningEvent) -> dict[str, Any] | None:
        response = await asyncio.to_thread(self._post_json, "/v1/experience", event.to_dict())
        if isinstance(response, dict):
            return response
        return None


class _LegacyLearningBridgeClient:
    def __init__(self) -> None:
        self.base_url = os.environ.get("INSIGHT_LEARNING_URL", "http://127.0.0.1:8001").rstrip("/")
        self.enabled = _env_bool("INSIGHT_LEARNING_ENABLED", True)
        self.timeout_seconds = _env_float("INSIGHT_LEARNING_TIMEOUT_SECONDS", 2.0)
        self.min_sql_confidence = _env_float("INSIGHT_LEARNING_MIN_SQL_CONFIDENCE", 0.82)

    def _post_json(self, path: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        if not self.enabled:
            return None
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str).encode("utf-8")
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            method="POST",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                response_body = response.read().decode("utf-8")
                return json.loads(response_body) if response_body else {}
        except urllib.error.HTTPError as exc:
            try:
                logger.warning("Insight Learning HTTP %s on %s: %s", exc.code, path, exc.read().decode("utf-8", errors="ignore"))
            except Exception:
                logger.warning("Insight Learning HTTP %s on %s", exc.code, path)
        except Exception as exc:
            logger.debug("Insight Learning bridge call failed for %s: %s", path, exc)
        return None

    async def plan(self, abstraction: SafeQueryAbstraction) -> LearningPlanResult | None:
        response = await asyncio.to_thread(self._post_json, "/v1/plan", abstraction.to_plan_request())
        if not response or not isinstance(response, dict):
            return None
        plan = response.get("plan")
        if not isinstance(plan, dict) or not plan:
            return None
        route = "operation" if str(plan.get("action") or "").lower() == "categorize" else "sql"
        confidence = float(response.get("confidence") or 0.0)
        plan_source = str(response.get("plan_source") or "experience_transfer")
        accepted = route == "sql" and confidence >= self.min_sql_confidence and plan_source != "deterministic_fallback"
        critic_notes: list[str] = []
        critic_status = response.get("critic_status")
        if isinstance(critic_status, dict):
            critic_notes = [str(note) for note in critic_status.get("notes") or [] if note]
        return LearningPlanResult(
            accepted=accepted,
            confidence=confidence,
            plan_source=plan_source,
            route=route,
            plan=plan,
            skill_id=response.get("skill_id"),
            plan_template_id=response.get("plan_template_id"),
            message=critic_notes[0] if critic_notes else "",
            raw_response=response,
            reverse_field_map=abstraction.reverse_field_map,
        )

    async def ingest(self, event: LearningEvent) -> dict[str, Any] | None:
        response = await asyncio.to_thread(self._post_json, "/v1/experience", event.to_dict())
        if isinstance(response, dict):
            return response
        return None


_LEARNING_BRIDGE: LearningBridgeClient | None = None


def get_learning_bridge() -> LearningBridgeClient:
    global _LEARNING_BRIDGE
    if _LEARNING_BRIDGE is None:
        _LEARNING_BRIDGE = LearningBridgeClient()
    return _LEARNING_BRIDGE
