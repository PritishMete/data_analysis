"""Read-only, deterministic enhancements for multi-table detail analysis."""

from __future__ import annotations

from typing import Any

import pandas as pd


_MEASURE_WORDS = ("amount", "revenue", "sales", "profit", "cost", "quantity", "qty", "total")
_DATE_WORDS = ("date", "time", "timestamp", "month", "year", "day")


def _key(profile: dict[str, Any]) -> str | None:
    candidates = profile.get("business_key_candidates", [])
    return candidates[0] if candidates else None


def _measure_columns(profile: dict[str, Any]) -> list[str]:
    return [
        entry["column"]
        for entry in profile.get("schema", [])
        if entry.get("role") == "numeric_measure"
        and not any(word in entry["column"].casefold() for word in ("id", "key", "code", "rate", "pct", "percent"))
    ]


def duplicate_analysis(tables: dict[str, pd.DataFrame], profiles: dict[str, dict[str, Any]], fact_tables: list[str], dimension_tables: list[str]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    impact: dict[str, Any] = {}
    for name, frame in tables.items():
        profile = profiles[name]
        key = _key(profile)
        exact_rows = int(frame.duplicated().sum())
        groups = identical_groups = conflicting_groups = 0
        examples: list[dict[str, Any]] = []
        if key and key in frame.columns:
            grouped = frame[frame[key].notna()].groupby(key, dropna=True, sort=False)
            non_key = [column for column in frame.columns if column != key]
            for value, group in grouped:
                if len(group) <= 1:
                    continue
                groups += 1
                if group[non_key].drop_duplicates().shape[0] == 1:
                    identical_groups += 1
                    kind = "IDENTICAL KEY DUPLICATE"
                else:
                    conflicting_groups += 1
                    kind = "CONFLICTING KEY DUPLICATE"
                if len(examples) < 5:
                    examples.append({"key": str(value), "rows": int(len(group)), "classification": kind})
        # A repeated candidate key is not automatically a valid event repeat:
        # only a non-key event identifier can repeat safely at event grain.
        repeated_event_groups = 0
        assessment = "No duplicate key issue observed."
        if name in fact_tables and groups:
            assessment = "Repeated event keys are reported separately; confirm the event grain before treating them as errors."
        elif groups:
            assessment = "Duplicate entity keys require resolution before this table can safely act as a dimension."
        output[name] = {
            "candidate_key": key,
            "exact_duplicate_rows": exact_rows,
            "duplicate_key_groups": groups,
            "identical_duplicate_key_groups": identical_groups,
            "conflicting_duplicate_key_groups": conflicting_groups,
            "repeated_event_groups_ignored": repeated_event_groups,
            "examples": examples,
            "assessment": assessment,
        }
        if exact_rows and name in fact_tables:
            duplicate_rows = frame[frame.duplicated(keep="first")]
            measures: dict[str, Any] = {}
            for column in _measure_columns(profile):
                values = pd.to_numeric(duplicate_rows[column], errors="coerce").dropna()
                total = pd.to_numeric(frame[column], errors="coerce").sum()
                duplicate_total = float(values.sum())
                measures[column] = {
                    "duplicate_value": duplicate_total,
                    "raw_total": float(total),
                    "potential_effect_percent": round(abs(duplicate_total / total) * 100, 4) if total else None,
                }
            impact[name] = {
                "exact_duplicate_rows": exact_rows,
                "percentage_of_rows": round(exact_rows / len(frame) * 100, 4) if len(frame) else 0,
                "potential_event_count_inflation": exact_rows,
                "measures": measures,
                "wording": "POTENTIAL IMPACT only; no rows were removed.",
            }
        elif name in dimension_tables and groups:
            counts = frame[key].value_counts(dropna=True) if key else pd.Series(dtype="int64")
            impact[name] = {
                "duplicate_key_groups": groups,
                "max_rows_per_key": int(counts.max()) if len(counts) else 0,
                "join_multiplication_risk": "HIGH" if groups else "LOW",
                "wording": "Potential join multiplication risk; multiplication was not assumed without an evaluated join.",
            }
    return {"duplicate_analysis": output, "duplicate_impact": impact}


def numeric_profiles(tables: dict[str, pd.DataFrame], profiles: dict[str, dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for name, frame in tables.items():
        entries: list[dict[str, Any]] = []
        for column in _measure_columns(profiles[name]):
            values = pd.to_numeric(frame[column], errors="coerce")
            values = values[values.notna() & values.map(pd.api.types.is_number) & values.map(lambda value: value not in (float("inf"), float("-inf")))]
            if values.empty:
                continue
            q1, q3 = values.quantile([0.25, 0.75])
            iqr = q3 - q1
            lower, upper = q1 - 1.5 * iqr, q3 + 1.5 * iqr
            outliers = int(((values < lower) | (values > upper)).sum()) if iqr else 0
            mean = float(values.mean())
            median = float(values.median())
            skew = float(values.skew()) if len(values) > 2 else 0.0
            distribution = "NEAR-CONSTANT" if iqr == 0 else "STRONGLY RIGHT-SKEWED" if skew > 1 else "STRONGLY LEFT-SKEWED" if skew < -1 else "BROAD DISTRIBUTION"
            entries.append({"column": column, "valid_count": int(len(values)), "null_count": int(frame[column].isna().sum()), "min": float(values.min()), "max": float(values.max()), "mean": mean, "median": median, "std": float(values.std()) if len(values) > 1 else 0.0, "q1": float(q1), "q3": float(q3), "iqr": float(iqr), "iqr_lower": float(lower), "iqr_upper": float(upper), "iqr_outliers": outliers, "outlier_percent": round(outliers / len(values) * 100, 4), "distribution": distribution, "interpretation": "Statistical observation only; business interpretation requires domain confirmation."})
        result[name] = entries
    return result


def date_profiles(tables: dict[str, pd.DataFrame], profiles: dict[str, dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for name, frame in tables.items():
        entries: list[dict[str, Any]] = []
        for entry in profiles[name].get("schema", []):
            column = entry["column"]
            if entry.get("logical_type") != "datetime" and not any(word in column.casefold() for word in _DATE_WORDS):
                continue
            parsed = pd.to_datetime(frame[column], errors="coerce")
            valid = parsed.dropna().dt.normalize()
            if valid.empty:
                entries.append({"column": column, "valid_count": 0, "invalid_count": int(frame[column].notna().sum()), "null_count": int(frame[column].isna().sum()), "freshness_status": "INSUFFICIENT EVIDENCE"})
                continue
            minimum, maximum = valid.min(), valid.max()
            active = set(valid.tolist())
            calendar = pd.date_range(minimum, maximum, freq="D")
            absent = [day.strftime("%Y-%m-%d") for day in calendar if day not in active]
            longest = 0
            current = 0
            for day in calendar:
                if day not in active:
                    current += 1
                    longest = max(longest, current)
                else:
                    current = 0
            entries.append({"column": column, "valid_count": int(valid.size), "invalid_count": int(frame[column].notna().sum() - valid.size), "null_count": int(frame[column].isna().sum()), "min_valid_date": minimum.strftime("%Y-%m-%d"), "max_valid_date": maximum.strftime("%Y-%m-%d"), "unique_date_count": int(valid.nunique()), "calendar_span_days": int((maximum - minimum).days + 1), "active_date_count": int(len(active)), "no_record_date_count": len(absent), "no_record_date_percent": round(len(absent) / len(calendar) * 100, 4), "longest_no_record_gap": longest, "freshness_status": "INSUFFICIENT EVIDENCE", "freshness_reason": "No expected refresh frequency was supplied; latest date is an observation, not a stale-data conclusion."})
        result[name] = entries
    return result


def kpi_readiness(tables: dict[str, pd.DataFrame], profiles: dict[str, dict[str, Any]], fact_tables: list[str], dimension_tables: list[str], duplicate_data: dict[str, Any], relationships: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for fact in fact_tables:
        profile = profiles[fact]
        duplicate = duplicate_data.get("duplicate_analysis", {}).get(fact, {})
        impact = duplicate_data.get("duplicate_impact", {}).get(fact, {})
        for measure in _measure_columns(profile):
            status = "READY WITH CAVEAT" if impact.get("exact_duplicate_rows") else "READY"
            risks = "exact duplicate fact rows may inflate totals" if impact.get("exact_duplicate_rows") else "no material duplicate-fact issue observed"
            output.append({"kpi": f"Total {measure}", "required_measure": measure, "required_grain": profile.get("dataset_overview", {}).get("grain"), "relationship_dependencies": [f"{r['source_column']} -> {r['target_table']}.{r['target_column']}" for r in relationships if r["source_table"] == fact], "known_issue": risks, "readiness": status, "reason": "The measure exists at the fact candidate grain; quality caveats remain explicit."})
        key = _key(profile)
        if key:
            dimension_key_issue = any(r.get("target_unique") is False for r in relationships if r["source_table"] == fact)
            output.append({"kpi": f"Distinct {key}", "required_measure": key, "required_grain": profile.get("dataset_overview", {}).get("grain"), "relationship_dependencies": [], "known_issue": "duplicate dimension key may affect entity interpretation" if dimension_key_issue else "none observed", "readiness": "BLOCKED" if dimension_key_issue else "READY", "reason": "Distinct-count semantics require a resolvable identity key."})
        quantity = next((entry["column"] for entry in profile.get("schema", []) if entry["column"].casefold() in {"quantity", "qty"}), None)
        if quantity and (pd.to_numeric(tables[fact][quantity], errors="coerce") < 0).any():
            output.append({"kpi": "Return rate", "required_measure": "validated return indicator or negative-quantity rule", "required_grain": profile.get("dataset_overview", {}).get("grain"), "relationship_dependencies": [], "known_issue": "negative quantity exists but return meaning is not confirmed", "readiness": "INSUFFICIENT EVIDENCE", "reason": "A business-rule inference must not be presented as fact."})
    return output
