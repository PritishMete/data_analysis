"""Deterministic local conversation state and next-question suggestions for InsightFlow."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any
import re

HISTORY_LIMIT = 20
RECENT_SUGGESTION_LIMIT = 12


@dataclass
class AnalyticalSessionState:
    session_id: str
    current_scope: str = "global"
    active_filters: dict[str, Any] = field(default_factory=dict)
    selected_entity: str | None = None
    selected_entity_type: str | None = None
    comparison_entities: list[str] = field(default_factory=list)
    current_metric: str | None = None
    current_grain: str | None = None
    time_scope: dict[str, Any] = field(default_factory=dict)
    recent_queries: list[str] = field(default_factory=list)
    recent_analyses: list[dict[str, Any]] = field(default_factory=list)
    surfaced_insights: list[dict[str, Any]] = field(default_factory=list)
    generated_reports: list[dict[str, Any]] = field(default_factory=list)
    recent_suggestions: list[str] = field(default_factory=list)
    last_successful_result: dict[str, Any] | None = None
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class ConversationStateStore:
    def __init__(self) -> None:
        self._states: dict[str, AnalyticalSessionState] = {}

    def get(self, session_id: str) -> AnalyticalSessionState:
        key = str(session_id or "").strip()
        if not key:
            raise ValueError("session_id is required")
        if key not in self._states:
            self._states[key] = AnalyticalSessionState(session_id=key)
        return self._states[key]

    def snapshot(self, session_id: str) -> AnalyticalSessionState:
        return deepcopy(self.get(session_id))

    def restore(self, session_id: str, snapshot: AnalyticalSessionState) -> AnalyticalSessionState:
        self._states[session_id] = deepcopy(snapshot)
        return self._states[session_id]

    def reset_active_scope(self, session_id: str) -> AnalyticalSessionState:
        state = self.get(session_id)
        state.current_scope = "global"
        state.active_filters = {}
        state.selected_entity = None
        state.selected_entity_type = None
        state.comparison_entities = []
        state.current_metric = None
        state.current_grain = None
        state.time_scope = {}
        state.updated_at = datetime.now(timezone.utc).isoformat()
        return state

    def record_success(self, session_id: str, payload: dict[str, Any]) -> AnalyticalSessionState:
        state = self.get(session_id)
        query = str(payload.get("query") or "").strip()
        if query:
            state.recent_queries.append(query)
            state.recent_queries = state.recent_queries[-HISTORY_LIMIT:]

        if payload.get("reset_scope") is True:
            self.reset_active_scope(session_id)
            state = self.get(session_id)

        for name in ("current_scope", "selected_entity", "selected_entity_type", "current_metric", "current_grain"):
            if name in payload and payload[name] is not None:
                setattr(state, name, payload[name])

        if isinstance(payload.get("active_filters"), dict):
            state.active_filters = deepcopy(payload["active_filters"])
        if isinstance(payload.get("time_scope"), dict):
            state.time_scope = deepcopy(payload["time_scope"])
        if isinstance(payload.get("comparison_entities"), list):
            state.comparison_entities = [str(x) for x in payload["comparison_entities"] if str(x).strip()]

        analysis = payload.get("analysis")
        if isinstance(analysis, dict):
            compact = {
                key: deepcopy(analysis.get(key))
                for key in ("type", "scope", "grain", "metric", "selected_entity", "summary")
                if analysis.get(key) is not None
            }
            if compact:
                state.recent_analyses.append(compact)
                state.recent_analyses = state.recent_analyses[-HISTORY_LIMIT:]

        if isinstance(payload.get("surfaced_insights"), list):
            state.surfaced_insights = deepcopy(payload["surfaced_insights"][-HISTORY_LIMIT:])
        if isinstance(payload.get("report"), dict):
            report = {
                key: deepcopy(payload["report"].get(key))
                for key in ("filename", "report_type", "scope", "generated_at")
                if payload["report"].get(key) is not None
            }
            if report:
                state.generated_reports.append(report)
                state.generated_reports = state.generated_reports[-HISTORY_LIMIT:]
        if isinstance(payload.get("result"), dict):
            state.last_successful_result = deepcopy(payload["result"])

        state.updated_at = datetime.now(timezone.utc).isoformat()
        return state


STORE = ConversationStateStore()


def looks_like_session_summary(text: str) -> bool:
    normalized = re.sub(r"\s+", " ", str(text or "").casefold()).strip()
    phrases = (
        "summarize our analysis",
        "summarise our analysis",
        "what have we analyzed",
        "what have we analysed",
        "what is the current scope",
        "what are we looking at now",
        "analysis history",
        "summarize this analysis",
        "summarise this analysis",
    )
    return any(phrase in normalized for phrase in phrases)


def _suggestion(id_: str, label: str, query: str, reason: str, priority: int, category: str) -> dict[str, Any]:
    return {"id": id_, "label": label, "query": query, "reason": reason, "priority": priority, "category": category}


def _candidate_suggestions(state: AnalyticalSessionState, context: dict[str, Any]) -> list[dict[str, Any]]:
    kind = str(context.get("intent") or context.get("current_intent") or "").casefold()
    entity_type = str(context.get("selected_entity_type") or state.selected_entity_type or "").casefold()
    entity = str(context.get("selected_entity") or state.selected_entity or "").strip()
    comparisons = context.get("comparison_entities") if isinstance(context.get("comparison_entities"), list) else state.comparison_entities
    out: list[dict[str, Any]] = []

    if kind in {"assistant_meta", "identity", "creator", "privacy", "usage", "tech_stack"}:
        return []

    if "quality" in kind:
        return [
            _suggestion("quality-impact", "Which issues materially affect business KPIs?", "Which issues materially affect business KPIs?", "Prioritize quality findings by analytical impact.", 100, "quality"),
            _suggestion("quality-customer", "Show customer-related issues", "Show customer-related issues", "Drill into customer quality findings.", 90, "quality"),
            _suggestion("quality-product", "Show product-related issues", "Show product-related issues", "Drill into product quality findings.", 85, "quality"),
            _suggestion("quality-priority", "Which issues should be fixed first?", "Which issues should be fixed first?", "Convert quality findings into an ordered review list.", 80, "quality"),
        ]

    if comparisons or "comparison" in kind:
        left = str(comparisons[0]) if comparisons else "the first entity"
        right = str(comparisons[1]) if len(comparisons) > 1 else "the second entity"
        return [
            _suggestion("compare-margin", "Which one has the better margin?", "Which one has the better margin?", "Continue the active comparison with a profitability metric.", 100, "comparison"),
            _suggestion("compare-why", f"Why is {left} more profitable than {right}?", f"Why is {left} more profitable than {right}?", "Explain the comparison from local evidence.", 95, "comparison"),
            _suggestion("compare-monthly", "Compare them month by month", "Compare them month by month", "Inspect whether the gap is persistent or period-specific.", 90, "time"),
            _suggestion("compare-year", "What about 2024?", "What about 2024?", "Replace the active year while preserving the comparison pair.", 85, "time"),
            _suggestion("compare-report", "Generate a comparison report", "Generate a comparison report", "Export the active comparison.", 70, "report"),
        ]

    if entity and entity_type in {"region", "business_region"}:
        return [
            _suggestion("region-year", f"How did {entity} perform in 2025?", f"How did {entity} perform in 2025?", "Add a year scope to the selected region.", 100, "time"),
            _suggestion("region-compare", f"Compare {entity} with the next-best region", f"Compare {entity} with the next-best region", "Benchmark the selected region.", 95, "comparison"),
            _suggestion("region-category", f"Which categories contribute most to {entity}'s profit?", f"Which categories contribute most to {entity}'s profit?", "Drill into the selected region by category.", 90, "drill_down"),
            _suggestion("region-monthly", f"Show {entity} month by month", f"Show {entity} month by month", "Inspect the selected region over time.", 85, "time"),
            _suggestion("region-report", f"Generate a report for {entity}", f"Generate a report for {entity}", "Export the selected region analysis.", 70, "report"),
        ]

    if entity and entity_type == "product":
        return [
            _suggestion("product-profit", "How profitable is it?", "How profitable is it?", "Continue with profitability for the selected product.", 100, "drill_down"),
            _suggestion("product-year", "What about in 2025?", "What about in 2025?", "Add a year scope while preserving the selected product.", 95, "time"),
            _suggestion("product-compare", "Compare it with another top product", "Compare it with another top product", "Benchmark the selected product.", 90, "comparison"),
            _suggestion("product-monthly", "Show its monthly trend", "Show its monthly trend", "Inspect product performance over time.", 85, "time"),
            _suggestion("product-report", "Generate a report for this product", "Generate a report for this product", "Export the selected product analysis.", 70, "report"),
        ]

    if entity and entity_type == "category":
        return [
            _suggestion("category-product", "Which products drive this category?", "Which products drive this category?", "Drill from category to product.", 100, "drill_down"),
            _suggestion("category-year", "How did this category perform in 2025?", "How did this category perform in 2025?", "Add a year scope to the category.", 90, "time"),
            _suggestion("category-report", "Generate a report for this category", "Generate a report for this category", "Export the selected category analysis.", 70, "report"),
        ]

    out.extend([
        _suggestion("global-time", "Compare 2024 with 2025", "Compare 2024 with 2025", "Add a time comparison to the current analysis.", 80, "time"),
        _suggestion("global-insight", "What should I pay attention to here?", "What should I pay attention to here?", "Surface prioritized local insights.", 75, "insight"),
        _suggestion("global-quality", "Are there data-quality issues affecting this result?", "Are there data-quality issues affecting this result?", "Check whether quality caveats affect interpretation.", 65, "quality"),
        _suggestion("global-report", "Generate a report from this analysis", "Generate a report from this analysis", "Export the current analytical context.", 60, "report"),
    ])
    return out


def generate_suggestions(session_id: str, context: dict[str, Any] | None = None, limit: int = 5) -> list[dict[str, Any]]:
    state = STORE.get(session_id)
    context = context or {}
    already_asked = {q.casefold().strip() for q in state.recent_queries}
    recently_shown = {q.casefold().strip() for q in state.recent_suggestions}
    unique: dict[str, dict[str, Any]] = {}
    for item in sorted(_candidate_suggestions(state, context), key=lambda x: (-int(x["priority"]), x["id"])):
        key = str(item["query"]).casefold().strip()
        if not key or key in already_asked or key in recently_shown or key in unique:
            continue
        unique[key] = item
    selected = list(unique.values())[: max(0, min(int(limit), 8))]
    state.recent_suggestions.extend(item["query"] for item in selected)
    state.recent_suggestions = state.recent_suggestions[-RECENT_SUGGESTION_LIMIT:]
    return selected


def build_session_summary(session_id: str) -> dict[str, Any]:
    state = STORE.get(session_id)
    scope = state.current_scope or "global"
    filters = deepcopy(state.active_filters)
    summary_lines: list[str] = [f"Current scope: {scope}."]
    if filters:
        summary_lines.append("Active filters: " + ", ".join(f"{k}={v}" for k, v in filters.items()) + ".")
    if state.selected_entity:
        label = state.selected_entity_type or "entity"
        summary_lines.append(f"Selected {label}: {state.selected_entity}.")
    if state.current_metric:
        summary_lines.append(f"Current metric: {state.current_metric}.")
    return {
        "success": True,
        "response_type": "session_summary",
        "title": "Analysis Summary",
        "summary": " ".join(summary_lines),
        "current_scope": scope,
        "active_filters": filters,
        "selected_entity": state.selected_entity,
        "selected_entity_type": state.selected_entity_type,
        "current_metric": state.current_metric,
        "current_grain": state.current_grain,
        "time_scope": deepcopy(state.time_scope),
        "recent_analyses": deepcopy(state.recent_analyses),
        "generated_reports": deepcopy(state.generated_reports),
        "privacy": {"local_state_only": True, "external_ai_used": False},
    }
