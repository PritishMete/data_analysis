from __future__ import annotations

from dataclasses import dataclass, field, asdict
import re
from typing import Any

import pandas as pd

from schema_intelligence.semantic_engine import SemanticField, SemanticSchema

_MONTHS = {m.casefold(): i for i, m in enumerate(("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"), 1)}
_MONTHS.update({m.casefold(): i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)})
_LOSS_TERMS = ("loss", "losses", "losing", "loss-making", "lossmaking", "negative")

@dataclass(frozen=True)
class SemanticQueryPlan:
    intent: str
    dimensions: list[str] = field(default_factory=list)
    metric: str | None = None
    aggregation: str | None = None
    time_field: str | None = None
    time_grain: str | None = None
    time_filter: dict[str, Any] | None = None
    filters: list[dict[str, Any]] = field(default_factory=list)
    sort: str | None = None
    limit: int | None = None
    confidence: float = 0.0
    assumptions: list[str] = field(default_factory=list)
    ambiguities: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class SemanticQueryPlanner:
    """Deterministic planner over SemanticSchema.

    This is intentionally a planning layer, not an execution engine. Existing
    query_router execution remains the local authority. The planner resolves
    concepts and ambiguity without seeing private cell values.
    """

    def plan(self, text: str, schema: SemanticSchema) -> SemanticQueryPlan:
        query = text.casefold()
        fields = schema.fields
        metric = self._resolve_metric(query, fields)
        dimensions = self._resolve_dimensions(query, fields)
        time_field, time_ambiguities = self._resolve_time_field(query, fields)
        month = self._resolve_month(query)
        intent = self._intent(query)
        aggregation = "sum" if metric and intent in {"aggregation", "ranking", "comparison", "trend"} else None
        if metric:
            mf = next((f for f in fields if f.name == metric), None)
            if mf and mf.business_role == "profit" and any(w in query for w in _LOSS_TERMS):
                filters = [{"field": metric, "operator": "less_than", "value": 0}]
            else:
                filters = []
        else:
            filters = []

        assumptions: list[str] = []
        ambiguities = list(time_ambiguities)
        if time_field and month:
            assumptions.append(f"{time_field} defines the requested month filter")
        if metric and aggregation:
            assumptions.append(f"{aggregation} is the default aggregation for {metric}")

        if "top" in query or "bottom" in query:
            match = re.search(r"\b(?:top|bottom)\s+(\d+)\b", query)
            limit = int(match.group(1)) if match else 10
            sort = "desc" if "top" in query else "asc"
        else:
            limit, sort = None, None

        confidence = 0.5
        resolved = sum(x is not None for x in (metric, time_field)) + min(2, len(dimensions))
        confidence += min(0.4, resolved * 0.1)
        if ambiguities:
            confidence = min(confidence, 0.65)
        return SemanticQueryPlan(
            intent=intent,
            dimensions=dimensions,
            metric=metric,
            aggregation=aggregation,
            time_field=time_field,
            time_grain="month" if month or any(w in query for w in ("monthly", "per month", "by month")) else None,
            time_filter={"month": month} if month else None,
            filters=filters,
            sort=sort,
            limit=limit,
            confidence=round(min(confidence, 0.99), 4),
            assumptions=assumptions,
            ambiguities=ambiguities,
        )

    @staticmethod
    def _intent(query: str) -> str:
        if any(w in query for w in ("top", "bottom", "best", "worst", "ranking")):
            return "ranking"
        if any(w in query for w in ("trend", "monthly", "weekly", "daily", "over time")):
            return "trend"
        if any(w in query for w in ("compare", "versus", "vs", "difference")):
            return "comparison"
        return "aggregation" if any(w in query for w in ("revenue", "sales", "profit", "total", "average", "sum")) else "analysis"

    @staticmethod
    def _resolve_month(query: str) -> int | None:
        for token, month in _MONTHS.items():
            if re.search(rf"\b{re.escape(token)}\b", query):
                return month
        return None

    @staticmethod
    def _resolve_metric(query: str, fields: list[SemanticField]) -> str | None:
        measures = [f for f in fields if f.analytical_role == "measure" and f.semantic_role not in {"rating", "count"}]
        loss_query = any(term in query for term in _LOSS_TERMS)
        scored: list[tuple[int, float, str]] = []
        for field in measures:
            score = 0
            if field.business_role:
                aliases = {field.business_role.replace("_", " "), field.business_role}
                if any(alias in query for alias in aliases):
                    score += 5
                if loss_query and field.business_role == "profit":
                    score += 8
            if field.name.casefold() in query:
                score += 3
            score += int(field.confidence * 2)
            if score:
                scored.append((score, field.confidence, field.name))
        return max(scored)[2] if scored else (measures[0].name if len(measures) == 1 else None)

    @staticmethod
    def _resolve_dimensions(query: str, fields: list[SemanticField]) -> list[str]:
        dimensions = [f for f in fields if f.analytical_role == "dimension"]
        scored: list[tuple[int, float, str]] = []
        for field in dimensions:
            tokens = set(re.findall(r"[a-z0-9]+", field.name.casefold()))
            if field.business_role:
                tokens.update(field.business_role.replace("_", " ").split())
            score = 0
            for token in tokens:
                if len(token) <= 2:
                    continue
                pattern = rf"\b(?:{re.escape(token)}|{re.escape(token[:-1] + 'ies') if token.endswith('y') else re.escape(token + 's')})\b"
                if re.search(pattern, query):
                    score += 1
            if score:
                scored.append((score, field.confidence, field.name))
        return [item[2] for item in sorted(scored, key=lambda x: (x[0], x[1]), reverse=True)[:2]]

    @staticmethod
    def _resolve_time_field(query: str, fields: list[SemanticField]) -> tuple[str | None, list[dict[str, Any]]]:
        time_fields = [f for f in fields if f.semantic_role in {"date", "datetime"}]
        if not time_fields:
            return None, []
        requested_delivery = any(w in query for w in ("deliver", "shipping", "shipment", "fulfil", "fulfill"))
        requested_transaction = any(w in query for w in ("sales", "sale", "order", "purchase", "transaction", "revenue"))
        scored: list[tuple[int, float, SemanticField]] = []
        for field in time_fields:
            score = int(field.confidence * 10)
            if requested_delivery and field.business_role == "delivery_date": score += 20
            if requested_transaction and field.business_role == "transaction_date": score += 20
            if field.business_role in {"delivery_date", "transaction_date"} and not (requested_delivery or requested_transaction):
                score += 2
            scored.append((score, field.confidence, field))
        scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
        best = scored[0][2]
        if len(scored) > 1 and scored[0][0] == scored[1][0]:
            return None, [{"type": "date_field", "candidates": [scored[0][2].name, scored[1][2].name]}]
        return best.name, []
