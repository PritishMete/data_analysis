"""Agentic value categorization.

The command agent only decides that a categorization operation was requested.
This module is the second agentic step: it sees the real distinct values in the
selected column, proposes a compact value -> category mapping, validates the
mapping, and applies it with pandas. This prevents the command parser from
hallucinating categories before it has seen the data.
"""
from __future__ import annotations

import json
import re
import traceback
import uuid
from typing import Any

import pandas as pd
from google.adk.agents import LlmAgent
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types
from privacy_context import strict_enabled

MODEL = "gemini-3.5-flash"

INSTRUCTION = """You are the Categorization Agent in an Excel data-analysis product.
Your job is to map EVERY distinct input value shown in the supplied value list to ONE
meaningful category.

Rules:
- Follow the user's requested categories exactly when they supplied them.
- If categories were not supplied, infer a small, useful set from the column name,
  user request, and actual values. Prefer 2-8 categories; do not create a category
  for every value unless the data genuinely requires it.
- Normalize obvious variants into the same category (e.g. Yes/yes/Y/Ye -> Yes,
  No/no/N -> No; India/india -> India; Asia/asia -> Asia).
- For rating-like values, preserve the requested rating semantics instead of inventing
  unrelated business categories.
- For text such as reviews, categorize by the themes actually present in the values
  (food, service, delivery, ambience, price/value, etc.) only when supported by the
  text and request.
- Do not modify the source values. The output is only a mapping to a new category.
- Every supplied value MUST appear exactly once in the mapping. Use unmatchedLabel only
  for values that cannot be confidently assigned.
- Return ONLY valid JSON with this shape:
{
  "categories": ["label", ...],
  "unmatchedLabel": "Other",
  "mapping": {"original value": "category"},
  "explanation": "short sentence"
}
"""


def _extract_json(text: str) -> str:
    text = (text or "").strip()
    fence = re.search(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL)
    if fence:
        return fence.group(1).strip()
    first, last = text.find("{"), text.rfind("}")
    return text[first:last + 1] if first >= 0 and last > first else text


async def _ask_agent(user_request: str, source_column: str, values: list[str], categories: list[str], unmatched: str) -> dict[str, Any]:
    agent = LlmAgent(name="categorization_agent", model=MODEL, instruction=INSTRUCTION,
                     description="Maps real spreadsheet values into useful categories.")
    session_service = InMemorySessionService()
    app_name = "categorization_agent_app"
    user_id = "api_user"
    session_id = str(uuid.uuid4())
    await session_service.create_session(app_name=app_name, user_id=user_id, session_id=session_id)
    runner = Runner(agent=agent, app_name=app_name, session_service=session_service)
    prompt = (
        f"Source column: {source_column}\n"
        f"User request: {user_request}\n"
        f"Requested categories: {json.dumps(categories, ensure_ascii=False)}\n"
        f"Fallback/unmatched label: {unmatched}\n"
        f"Distinct values ({len(values)}): {json.dumps(values, ensure_ascii=False)}"
    )
    final_text = None
    async for event in runner.run_async(user_id=user_id, session_id=session_id,
                                        new_message=types.Content(role="user", parts=[types.Part(text=prompt)])):
        if event.is_final_response() and event.content and event.content.parts:
            for part in event.content.parts:
                if getattr(part, "text", None):
                    final_text = part.text
    if not final_text:
        raise ValueError("The Categorization Agent returned no response.")
    parsed = json.loads(_extract_json(final_text))
    return parsed



def _deterministic_special_mapping(values: list[str], source_column: str) -> dict[str, str] | None:
    """Canonicalize high-confidence categorical variants without relying on the LLM.

    Boolean-like columns are handled *before* generic text/LLM categorization. This is
    important for real spreadsheets where a boolean column commonly contains mixed
    representations such as Y/N, Yes/No, 1/0, true/false, and Ye. The mapping is
    based on both the column name and the observed values, so a column named ``Bool``
    containing ``Y, N, 0, 1`` is always treated as boolean and never falls through to
    the generic text-normalization fallback.
    """
    name = re.sub(r"[^a-z0-9]", "", str(source_column).lower())
    low = {v: v.strip().lower() for v in values}
    boolean_tokens = {"yes", "no", "y", "n", "ye", "true", "false", "t", "f", "1", "0"}
    null_tokens = {"", "none", "null", "na", "n/a", "nan", "unknown"}

    # Explicit boolean/flag column names get the boolean mapping even when the
    # column has a small amount of missing data or mixed numeric/string storage.
    explicit_bool_name = (
        name in {"bool", "boolean", "flag", "binary", "binaryflag", "boolcolumn"}
        or name.startswith("is")
        or name.startswith("has")
        or name.endswith("flag")
    )
    observed = set(low.values())
    non_null = observed - null_tokens
    boolean_like = bool(non_null) and non_null.issubset(boolean_tokens)
    if explicit_bool_name or boolean_like:
        # Do not accidentally turn arbitrary empty text into Yes/No. Unknown/missing
        # values remain explicit so every row is still handled.
        return {
            original: ("Yes" if v in {"yes", "y", "ye", "true", "t", "1"}
                       else "No" if v in {"no", "n", "false", "f", "0"}
                       else "Unknown")
            for original, v in low.items()
        }

    # Country normalization: common casing, spelling, abbreviation and typo variants.
    if "country" in name or name in {"nation", "countryname"}:
        country_aliases = {
            "india": "India", "ind": "India", "in": "India", "idnia": "India",
            "uae": "UAE", "united arab emirates": "UAE", "arab": "UAE",
            "uk": "United Kingdom", "united kingdom": "United Kingdom",
            "us": "United States", "usa": "United States", "united states": "United States",
            "singapore": "Singapore", "singapor": "Singapore",
            "bangladesh": "Bangladesh", "bangladsh": "Bangladesh",
            "russia": "Russia", "canada": "Canada",
            "china": "China", "japan": "Japan", "germany": "Germany",
            "france": "France", "australia": "Australia",
        }
        out = {}
        for original, v in low.items():
            if v in country_aliases:
                out[original] = country_aliases[v]
            elif v in {"", "none", "null", "na", "n/a", "unknown"}:
                out[original] = "Unknown"
            else:
                # Preserve an unknown country rather than inventing a country.
                out[original] = re.sub(r"\s+", " ", v).strip().title()
        return out

    # Region normalization: case and common spelling variants.
    # City normalization: canonicalize common abbreviations/typos and casing.
    if "city" in name or name in {"town", "cityname"}:
        city_aliases = {
            "new delhi": "New Delhi", "delhi": "Delhi", "newdelhi": "New Delhi",
            "mumbai": "Mumbai", "bombay": "Mumbai",
            "kolkata": "Kolkata", "calcutta": "Kolkata",
            "gurgaon": "Gurgaon", "gurugram": "Gurgaon",
            "bangalore": "Bangalore", "bengaluru": "Bangalore",
            "hyderabad": "Hyderabad", "chennai": "Chennai", "madras": "Chennai",
            "pune": "Pune", "noida": "Noida", "faridabad": "Faridabad",
            "jaipur": "Jaipur", "ahmedabad": "Ahmedabad",
            "dubai": "Dubai", "abu dhabi": "Abu Dhabi", "abudhabi": "Abu Dhabi",
            "london": "London", "singapore": "Singapore", "dhaka": "Dhaka",
            "moscow": "Moscow", "new york": "New York", "newyork": "New York",
            "toronto": "Toronto",
        }
        out = {}
        for original, v in low.items():
            key = re.sub(r"\s+", " ", v).strip()
            out[original] = city_aliases.get(key, "Unknown" if key in {"", "none", "null", "na", "n/a", "unknown"} else key.title())
        return out

    # Review/comment text gets a local semantic categorization in local processing mode.
    # This keeps the original review text on-device while still producing useful
    # categories without sending the text to the external AI provider.
    if any(token in name for token in {"review", "comment", "feedback", "description", "text"}):
        def review_category(v: str) -> str:
            t = v.lower()
            if any(k in t for k in {"delivery", "delivered", "late delivery", "delivery late"}):
                return "Delivery"
            if any(k in t for k in {"wait", "waiting", "staff", "service", "rude"}):
                return "Service"
            if any(k in t for k in {"food", "pizza", "taste", "tasty", "portion", "cold"}):
                return "Food"
            if any(k in t for k in {"atmosphere", "ambience", "ambiance", "music", "environment"}):
                return "Atmosphere"
            if any(k in t for k in {"value", "price", "expensive", "cheap", "cost", "portion"}):
                return "Price/Value"
            if v.strip() == "":
                return "Unknown"
            return "Other"
        return {original: review_category(v) for original, v in low.items()}

    if "region" in name or name in {"area", "zone", "territory"}:
        region_aliases = {
            "asia": "Asia", "ncr": "NCR", "middle east": "Middle East",
            "middleeast": "Middle East", "europe": "Europe",
            "north america": "North America", "northamerica": "North America",
            "south america": "South America", "southamerica": "South America",
            "africa": "Africa", "oceania": "Oceania",
        }
        out = {}
        for original, v in low.items():
            key = re.sub(r"\s+", " ", v).strip()
            out[original] = region_aliases.get(key, "Unknown" if key in {"", "none", "null", "na", "n/a", "unknown"} else key.title())
        return out

    if "gender" in name or name in {"sex", "gendercode"}:
        out = {}
        for original, v in low.items():
            if v in {"m", "male", "man", "men"}:
                out[original] = "Male"
            elif v in {"f", "female", "femal", "femalle", "woman", "women"}:
                out[original] = "Female"
            elif v in {"nb", "nonbinary", "non-binary", "non binary"}:
                out[original] = "Non-binary"
            elif v in {"", "none", "null", "na", "n/a", "unknown"}:
                out[original] = "Unknown"
            else:
                out[original] = "Unknown"
        return out
    return None


def _deterministic_fallback_mapping(series: pd.Series) -> tuple[dict[str, str], list[str], str]:
    """Last-resort mapping: every distinct value gets a deterministic category.

    This guarantees multi-column categorization never reports a column as skipped.
    """
    values = []
    seen = set()
    for value in series.tolist():
        key = "" if pd.isna(value) else str(value)
        if key not in seen:
            seen.add(key); values.append(key)
    special = _deterministic_special_mapping(values, str(series.name))
    if special is not None:
        cats = sorted(set(special.values()))
        return special, cats, "Applied deterministic categorical normalization fallback."
    if pd.api.types.is_numeric_dtype(series):
        nums = pd.to_numeric(series, errors="coerce")
        valid = nums.dropna()
        if valid.empty:
            mapping = {v: ("Unknown" if v == "" else v.strip()) for v in values}
            return mapping, sorted(set(mapping.values())), "Normalized categorical values deterministically."
        q1, q2 = valid.quantile([1/3, 2/3]).tolist()
        def band(v):
            if v == "": return "Unknown"
            try:
                x = float(v)
                return "Low" if x <= q1 else "Medium" if x <= q2 else "High"
            except Exception:
                return "Unknown"
        mapping = {v: band(v) for v in values}
        return mapping, ["Low", "Medium", "High", "Unknown"], "Applied deterministic numeric band fallback."
    mapping = {}
    for v in values:
        normalized = re.sub(r"\s+", " ", v.strip())
        mapping[v] = normalized.title() if normalized else "Unknown"
    return mapping, sorted(set(mapping.values())), "Normalized categorical values deterministically."

async def categorize_dataframe(df: pd.DataFrame, source_column: str, new_column: str,
                         user_request: str, requested_categories: list[str] | None = None,
                         unmatched_label: str = "Other") -> tuple[pd.DataFrame, dict[str, Any]]:
    # Resolve column names case-insensitively and tolerate the common
    # "bool/boolean column" shorthand. The LLM may return "country" while
    # Excel's real header is "Country"; that should never be a failure.
    def _norm_col(value: Any) -> str:
        return re.sub(r"[^a-z0-9]", "", str(value).strip().lower())

    actual_source = next((c for c in df.columns if _norm_col(c) == _norm_col(source_column)), None)
    if actual_source is None and str(source_column).strip() == "__BOOLEAN_COLUMN__":
        def _looks_boolean(series: pd.Series) -> bool:
            vals = [str(v).strip().lower() for v in series.dropna().tolist()]
            if not vals:
                return False
            allowed = {"yes", "no", "y", "n", "true", "false", "t", "f", "1", "0", "ye"}
            return len(vals) > 0 and (len(set(vals)) <= 8) and all(v in allowed for v in vals)
        bool_candidates = [c for c in df.columns if _looks_boolean(df[c])]
        if bool_candidates:
            actual_source = bool_candidates[0]
    if actual_source is None:
        raise ValueError(f"Column '{source_column}' was not found.")
    source_column = str(actual_source)
    if not new_column.strip() or _norm_col(new_column) in {"__booleancolumn__", _norm_col("bool"), _norm_col("boolean")} :
        # Categorization is an in-place transformation. The source column is
        # the destination unless an explicit existing destination was supplied.
        new_column = source_column
    # In-place categorization is intentional: the categorized values replace
    # the original source column in the current worksheet. Never create a
    # *_Category companion column for this operation.

    series = df[source_column]
    values = []
    seen = set()
    for value in series.tolist():
        key = "" if pd.isna(value) else str(value)
        if key not in seen:
            seen.add(key)
            values.append(key)
    # A huge free-text/high-cardinality column is not safe to dump into an LLM.
    # Fail explicitly rather than producing a partial mapping.
    if len(values) > 1500:
        raise ValueError(
            f"'{source_column}' has {len(values)} distinct values. Categorization is limited to 1,500 distinct values at a time; filter the data or choose a lower-cardinality column."
        )

    requested_categories = [str(x).strip() for x in (requested_categories or []) if str(x).strip()]
    unmatched_label = str(unmatched_label or "Other").strip() or "Other"
    # Handle high-confidence spreadsheet categories deterministically first.
    special_mapping = _deterministic_special_mapping(values, source_column)
    if special_mapping is not None and not requested_categories:
        mapping = special_mapping
        categories = sorted(set(mapping.values()))
        fallback = unmatched_label
        plan = {"mapping": mapping, "categories": categories, "unmatchedLabel": fallback,
                "explanation": f"Normalized '{source_column}' using deterministic categorical rules."}
    else:
        money_like = bool(re.search(r"(currency|price|amount|cost|fare|salary|revenue|sales|income|budget|fee|charge|value)", source_column, re.I))
        if money_like and not requested_categories:
            mapping = {v: ("Unknown" if v.strip() == "" else v) for v in values}
            categories = sorted(set(mapping.values()))
            fallback = unmatched_label
            plan = {
                "mapping": mapping,
                "categories": categories,
                "unmatchedLabel": fallback,
                "explanation": f"Left monetary values in '{source_column}' unchanged because no currency conversion was requested.",
            }
        else:
            try:
                if strict_enabled():
                    raise RuntimeError("Local processing mode: real worksheet values are not sent to the external AI provider.")
                plan = await _ask_agent(user_request, source_column, values, requested_categories, unmatched_label)
                mapping_raw = plan.get("mapping") if isinstance(plan, dict) else None
                if not isinstance(mapping_raw, dict):
                    raise ValueError("The Categorization Agent did not return a valid value mapping.")
                mapping = {str(k): str(v) for k, v in mapping_raw.items()}
                categories = [str(x) for x in (plan.get("categories") or requested_categories) if str(x).strip()]
                fallback = str(plan.get("unmatchedLabel") or unmatched_label)
            except Exception as agent_exc:
                print(f"[categorization_agent] LLM failed for {source_column}; using deterministic fallback: {agent_exc}")
                mapping, categories, fallback_explanation = _deterministic_fallback_mapping(series)
                fallback = unmatched_label
                plan = {"mapping": mapping, "categories": categories, "unmatchedLabel": fallback,
                        "explanation": fallback_explanation}
    missing = [v for v in values if v not in mapping]
    if missing:
        # Never leave rows silently uncategorized.
        for v in missing:
            mapping[v] = fallback
    allowed = set(categories) | {fallback}
    invalid = sorted({v for v in mapping.values() if v not in allowed}) if allowed else []
    if invalid:
        # Keep the output deterministic even if the model added an unlisted label.
        categories.extend([v for v in invalid if v not in categories and v != fallback])

    out = df.copy()
    out[new_column] = out[source_column].map(lambda v: mapping.get("" if pd.isna(v) else str(v), fallback))
    metadata = {
        "source_column": source_column,
        "new_column": new_column,
        "write_mode": "replace_source",
        "categories": categories,
        "unmatched_label": fallback,
        "mapping": mapping,
        "distinct_values": len(values),
        "rows_affected": int(len(out)),
        "explanation": str(plan.get("explanation") or f"Categorized '{source_column}' into {len(categories)} categories."),
    }
    return out, metadata
