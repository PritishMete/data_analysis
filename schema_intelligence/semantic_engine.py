from __future__ import annotations

from dataclasses import asdict, dataclass, field
import re
from typing import Any

import pandas as pd

from schema_intelligence.contracts import ColumnContext
from schema_intelligence.registry import run_column_rules
from secure_excel.semantic_roles import detect_column_role

SEMANTIC_ROLES = {
    "identifier", "entity", "categorical", "ordinal", "boolean", "numeric_measure",
    "currency_measure", "percentage", "rating", "count", "quantity", "date", "datetime",
    "duration", "country", "region", "state", "city", "geography", "status", "free_text",
    "sentiment_text",
}

_BUSINESS_CONCEPTS: dict[str, tuple[str, ...]] = {
    "transaction_date": ("order", "purchase", "purchased", "transaction", "sale", "invoice", "booking", "sold"),
    "delivery_date": ("delivery", "delivered", "fulfilment", "fulfillment", "shipping", "shipped"),
    "signup_date": ("signup", "registration", "registered", "joined"),
    "birth_date": ("birth", "birthday", "dob"),
    "customer": ("customer", "client", "buyer", "account"),
    "product": ("product", "item", "sku"),
    "brand": ("brand",),
    "vendor": ("vendor", "supplier", "merchant"),
    "revenue": ("revenue", "sales", "turnover", "income"),
    "cost": ("cost", "expense", "spend"),
    "profit": ("profit", "margin", "earnings"),
    "discount": ("discount", "rebate"),
    "percentage": ("percentage", "percent", "pct", "rate"),
    "quantity": ("quantity", "qty", "units", "volume"),
    "count": ("count", "number", "total"),
    "duration": ("duration", "elapsed", "latency", "seconds", "minutes", "hours", "days"),
    "rating": ("rating", "score", "stars", "review"),
    "status": ("status", "stage", "condition"),
    "country": ("country", "nation"),
    "region": ("region", "territory", "area"),
    "state": ("state", "province"),
    "city": ("city", "town"),
    "geography": ("geography", "location", "address", "latitude", "longitude", "postal", "zip"),
}

_EXISTING_ROLE_MAP = {
    "primary_key": "identifier", "foreign_key": "identifier", "foreign_key_candidate": "identifier",
    "restaurant_entity": "entity", "customer_entity": "entity", "product_entity": "entity",
    "supplier_entity": "entity", "employee_entity": "entity", "entity_name": "entity",
    "geographic_area": "geography", "currency_metric": "currency_measure", "numeric_metric": "numeric_measure",
    "rating_metric": "rating", "boolean_capability": "boolean", "category": "categorical",
    "description": "free_text", "date": "date", "percentage": "percentage", "count": "count",
}
_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokens(name: str) -> set[str]:
    return set(_TOKEN_RE.findall(str(name).casefold().replace("_", " ").replace("-", " ")))


def _physical_type(series: pd.Series) -> str:
    if pd.api.types.is_bool_dtype(series): return "boolean"
    if pd.api.types.is_datetime64_any_dtype(series): return "datetime"
    if pd.api.types.is_integer_dtype(series): return "integer"
    if pd.api.types.is_float_dtype(series): return "float"
    if pd.api.types.is_numeric_dtype(series): return "numeric"
    if pd.api.types.is_string_dtype(series) or pd.api.types.is_object_dtype(series): return "string"
    return str(series.dtype)


def _business_role(column_name: str, inferred_role: str | None) -> tuple[str | None, float, list[str]]:
    tokens = _tokens(column_name)
    matches = []
    for concept, aliases in _BUSINESS_CONCEPTS.items():
        if concept.endswith("_date") and inferred_role not in {"date", "datetime"}:
            continue
        hit = sorted(tokens.intersection(aliases))
        if hit: matches.append((concept, len(hit), hit))
    if not matches: return None, 0.0, []
    matches.sort(key=lambda item: item[1], reverse=True)
    concept, score, evidence = matches[0]
    confidence = 0.72 if score == 1 else 0.88
    if inferred_role in {"date", "datetime"} and concept.endswith("_date"): confidence += 0.08
    if inferred_role in {"currency_measure", "numeric_measure"} and concept in {"revenue", "cost", "profit", "discount"}: confidence += 0.06
    return concept, min(0.99, confidence), evidence


def _role_from_business(concept: str | None, physical: str) -> str | None:
    if concept in {"country", "region", "state", "city", "geography"}: return concept
    if concept in {"customer", "product", "brand", "vendor"}: return "entity"
    if concept == "status": return "status"
    if concept == "percentage": return "percentage" if physical in {"integer", "float", "numeric"} else "categorical"
    if concept == "quantity": return "quantity" if physical in {"integer", "float", "numeric"} else "categorical"
    if concept == "count": return "count" if physical in {"integer", "float", "numeric"} else "categorical"
    if concept == "duration": return "duration" if physical in {"integer", "float", "numeric"} else "categorical"
    if concept == "rating": return "rating" if physical in {"integer", "float", "numeric"} else "categorical"
    return None


def _safe_shape(series: pd.Series) -> dict[str, Any]:
    non_null = series.dropna()
    count = int(len(series))
    unique = int(non_null.nunique())
    return {
        "non_null_count": int(len(non_null)),
        "missing_count": int(series.isna().sum()),
        "unique_count": unique,
        "cardinality_ratio": round(unique / count, 6) if count else 0.0,
    }


@dataclass(frozen=True)
class SemanticField:
    name: str
    physical_type: str
    semantic_role: str | None
    business_role: str | None
    nullable: bool
    uniqueness: float
    cardinality: int
    candidate_key: bool
    relationship_potential: bool
    analytical_role: str | None
    confidence: float
    evidence_categories: list[str] = field(default_factory=list)
    evidence: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]: return asdict(self)


@dataclass(frozen=True)
class SemanticSchema:
    fields: list[SemanticField]
    row_count: int
    table_grain: str | None = None

    def field(self, name: str) -> SemanticField | None:
        return next((f for f in self.fields if f.name == name), None)

    def to_safe_dict(self) -> dict[str, Any]:
        return {"row_count": self.row_count, "table_grain": self.table_grain, "fields": [f.to_dict() for f in self.fields]}


class SemanticSchemaEngine:
    """Shared adapter over existing Excel and schema-intelligence detectors."""

    def infer(self, df: pd.DataFrame, dataset_id: str = "local") -> SemanticSchema:
        fields: list[SemanticField] = []
        row_count = len(df)
        for raw_name in df.columns:
            name = str(raw_name)
            series = df[raw_name]
            excel = detect_column_role(name, series)
            context = ColumnContext(dataset_id=dataset_id, column_name=name, series=series, dataframe=df, row_count=row_count)
            candidates = run_column_rules(context)
            winning = candidates[0] if candidates else None
            existing_role = excel.get("role")
            mapped_role = _EXISTING_ROLE_MAP.get(existing_role, existing_role if existing_role in SEMANTIC_ROLES else None)
            physical = _physical_type(series)
            shape = _safe_shape(series)
            business, business_conf, business_tokens = _business_role(name, mapped_role)
            role_from_business = _role_from_business(business, physical)
            if mapped_role in {
                None, "categorical", "entity", "numeric_measure", "geography",
                "percentage", "rating", "count", "quantity", "duration",
            } and role_from_business is not None:
                mapped_role = role_from_business
            if role_from_business == "status":
                mapped_role = "status"
            if mapped_role == "date" and physical == "datetime": mapped_role = "datetime"

            rule_conf = float(winning.confidence) if winning else 0.0
            excel_conf = float(excel.get("confidence") or 0.0)
            confidence = max(rule_conf, excel_conf, business_conf if business else business_conf * 0.8)
            if physical == "boolean" and mapped_role is None: confidence = max(confidence, 0.9)
            if physical == "datetime" and mapped_role in {"date", "datetime"}: confidence = max(confidence, 0.95)

            cardinality = int(shape["unique_count"])
            uniqueness = round(cardinality / row_count, 6) if row_count else 0.0
            candidate_key = bool(row_count and cardinality == row_count and series.notna().all()) or existing_role == "identifier"
            key_named = bool(_tokens(name).intersection({"id", "key", "identifier"}))
            if candidate_key and (existing_role == "identifier" or key_named):
                mapped_role = "identifier"
            relationship_potential = candidate_key or mapped_role == "identifier"
            analytical_role = (
                "dimension" if mapped_role in {"categorical", "ordinal", "entity", "geography", "country", "region", "state", "city", "status"}
                else "measure" if mapped_role in {"numeric_measure", "currency_measure", "percentage", "rating", "count", "quantity", "duration"}
                else "time" if mapped_role in {"date", "datetime"} else None
            )
            evidence_categories = ["dtype", "cardinality", "existing_excel_semantic_detector"]
            if winning: evidence_categories.append("registered_rule")
            if business: evidence_categories.append("semantic_tokens")
            fields.append(SemanticField(
                name=name, physical_type=physical, semantic_role=mapped_role, business_role=business,
                nullable=bool(series.isna().any()), uniqueness=uniqueness, cardinality=cardinality,
                candidate_key=candidate_key, relationship_potential=relationship_potential,
                analytical_role=analytical_role, confidence=round(min(1.0, confidence), 4),
                evidence_categories=evidence_categories,
                evidence={
                    "existing_role": existing_role,
                    "existing_evidence": excel.get("evidence", []),
                    "registered_rule": winning.rule_name if winning else None,
                    "registered_rule_evidence": winning.evidence if winning else {},
                    "shape": shape,
                    "business_tokens": business_tokens,
                },
            ))
        return SemanticSchema(fields=fields, row_count=row_count)
