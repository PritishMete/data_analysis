"""Deterministic Chapter 6 analytics over the cleaned logical model."""

from __future__ import annotations

from typing import Any

import pandas as pd


HIGH_REVENUE_QUANTILE = 0.75
LOW_MARGIN_QUANTILE = 0.25
TOLERANCE = 1e-6


def _num(frame: pd.DataFrame, column: str) -> pd.Series:
    return pd.to_numeric(frame[column], errors="coerce")


def _norm(value: Any) -> str:
    return " ".join(str(value).strip().casefold().split())


def _rows(frame: pd.DataFrame) -> list[dict[str, Any]]:
    output = []
    for row in frame.to_dict(orient="records"):
        item = {}
        for key, value in row.items():
            if value is pd.NA or (isinstance(value, float) and pd.isna(value)):
                item[str(key)] = None
            elif hasattr(value, "item"):
                item[str(key)] = value.item()
            else:
                item[str(key)] = value
        output.append(item)
    return output


def _semantic_column(columns: list[str], words: tuple[str, ...], exclude: set[str] | None = None) -> str | None:
    exclude = exclude or set()
    ranked = []
    for column in columns:
        if column in exclude:
            continue
        name = column.casefold()
        score = sum(3 if name == word else 2 if word in name.split("_") else 1 if word in name else 0 for word in words)
        if score:
            ranked.append((score, -len(column), column))
    return max(ranked)[2] if ranked else None


def _measure_columns(fact: pd.DataFrame, event_key: str | None) -> list[str]:
    columns = []
    for column in fact.columns:
        if column in {event_key, "is_return"} or column.endswith("_parsed") or column.endswith("_status"):
            continue
        if pd.api.types.is_numeric_dtype(fact[column]):
            columns.append(column)
    return columns


def _margin(profit: pd.Series, revenue: pd.Series) -> pd.Series:
    return profit.div(revenue.where(revenue.ne(0)))


def _relationship_status(frame: pd.DataFrame, key: str, parent: pd.DataFrame, parent_key: str) -> tuple[pd.Series, int, int, float]:
    parent_values = set(parent[parent_key].dropna().map(_norm))
    non_null = frame[key].notna()
    valid = non_null & frame[key].map(lambda value: _norm(value) in parent_values)
    orphan = int((non_null & ~valid).sum())
    coverage = float(valid.sum() / non_null.sum()) if non_null.sum() else 0.0
    return valid, int((~non_null).sum()), orphan, coverage


def _join_dimension(fact: pd.DataFrame, key: str, dimension: pd.DataFrame, dimension_key: str, prefix: str) -> tuple[pd.DataFrame, dict[str, Any]]:
    valid, null_count, orphan_count, coverage = _relationship_status(fact, key, dimension, dimension_key)
    left = fact.copy(deep=True)
    lookup = dimension.drop_duplicates(subset=[dimension_key]).copy()
    lookup["__join_key"] = lookup[dimension_key].map(_norm)
    left["__join_key"] = left[key].map(_norm)
    joined = left.merge(lookup, on="__join_key", how="left", suffixes=("", f"_{prefix}"))
    return joined, {"source_column": key, "target_column": dimension_key, "null_fk_rows": null_count, "orphan_fk_rows": orphan_count, "non_null_referential_coverage": round(coverage, 6), "valid_rows": int(valid.sum())}


def _clean_frame(table: dict[str, Any]) -> pd.DataFrame:
    return pd.DataFrame(table.get("rows", []), columns=table.get("columns", []))


def analyze_clean_model(model: dict[str, Any]) -> dict[str, Any]:
    """Run all Chapter 6 calculations over Prompt 1-5 logical results."""
    required = {"fact_orders", "dim_customer", "dim_product", "dim_date", "dim_region"}
    if not required.issubset(model):
        return {"success": False, "status": "BLOCKED", "error": "Clean analytical model is required before Chapter 6."}
    fact = _clean_frame(model["fact_orders"])
    product = _clean_frame(model["dim_product"])
    region = _clean_frame(model["dim_region"])
    date = _clean_frame(model["dim_date"])
    if fact.empty or product.empty or date.empty:
        return {"success": False, "status": "BLOCKED", "error": "Clean analytical model is incomplete for Chapter 6."}

    event_key = model.get("fact_metadata", {}).get("event_key") or _semantic_column(list(fact.columns), ("order", "transaction", "event", "invoice"))
    revenue = _semantic_column(_measure_columns(fact, event_key), ("revenue", "sales", "amount"))
    profit = _semantic_column(_measure_columns(fact, event_key), ("profit",))
    cost = _semantic_column(_measure_columns(fact, event_key), ("cost",))
    if not revenue:
        return {"success": False, "status": "BLOCKED", "error": "No unambiguous revenue/sales measure was found in the cleaned fact."}
    derived_profit = False
    if not profit and cost:
        profit = "__derived_profit"
        fact[profit] = _num(fact, revenue) - _num(fact, cost)
        derived_profit = True
    if not profit:
        return {"success": False, "status": "BLOCKED", "error": "No direct profit measure or validated revenue-minus-cost measure was found."}

    customer = _clean_frame(model["dim_customer"])
    product_key = model.get("fact_metadata", {}).get("product_key") or _semantic_column(list(fact.columns), ("product", "item", "sku"))
    product_dim_key = product_key if product_key in product.columns else _semantic_column(list(product.columns), ("product", "item", "sku"))
    region_key = model.get("fact_metadata", {}).get("region_key") or _semantic_column(list(fact.columns), ("region", "geography", "area"))
    region_dim_key = region_key if region_key in region.columns else _semantic_column(list(region.columns), ("region", "geography", "area"))
    customer_key = model.get("fact_metadata", {}).get("customer_key") or _semantic_column(list(fact.columns), ("customer", "client", "member"))
    customer_dim_key = customer_key if customer_key in customer.columns else _semantic_column(list(customer.columns), ("customer", "client", "member"))
    if not product_key or not product_dim_key or not region_key or not region_dim_key:
        return {"success": False, "status": "BLOCKED", "error": "Validated product and region relationships are required for Chapter 6."}

    product_join, product_rel = _join_dimension(fact, product_key, product, product_dim_key, "product")
    region_join, region_rel = _join_dimension(fact, region_key, region, region_dim_key, "region")
    product_label = _semantic_column(list(product.columns), ("name", "description", "label"), {product_dim_key})
    category = _semantic_column(list(product.columns), ("category",))
    subcategory = _semantic_column(list(product.columns), ("subcategory", "sub_category"))
    display_label = product_label or product_dim_key

    def aggregate(frame: pd.DataFrame, key: str, label: str | None = None) -> pd.DataFrame:
        grouped = frame.groupby(key, dropna=False, sort=True)
        result = grouped.agg(revenue=(revenue, "sum"), profit=(profit, "sum"), order_count=(revenue, "size")).reset_index()
        if label and label in frame:
            labels = frame.groupby(key, dropna=False, sort=True)[label].first().reset_index(name="product")
            result = result.merge(labels, on=key, how="left")
        result["profit_margin"] = _margin(result["profit"], result["revenue"])
        return result

    product_named = product_join[product_join[display_label].notna()]
    product_agg = aggregate(product_named, product_dim_key, display_label)
    if category and category in product_named:
        product_agg = product_agg.merge(product_named.groupby(product_dim_key, sort=True)[category].first().reset_index(name="category"), on=product_dim_key, how="left")
    if subcategory and subcategory in product_named:
        product_agg = product_agg.merge(product_named.groupby(product_dim_key, sort=True)[subcategory].first().reset_index(name="sub_category"), on=product_dim_key, how="left")
    product_agg = product_agg.sort_values(["revenue", product_dim_key], ascending=[False, True], kind="mergesort").reset_index(drop=True)
    product_agg.insert(0, "rank", range(1, len(product_agg) + 1))
    top_products = product_agg.head(10).copy()
    total_revenue = float(_num(fact, revenue).sum())
    named_revenue = float(product_agg["revenue"].sum())
    unassigned_product_revenue = total_revenue - named_revenue
    product_reconciliation = {"clean_fact_revenue": total_revenue, "named_product_revenue": named_revenue, "unassigned_product_revenue": unassigned_product_revenue, "reconciles": abs(named_revenue + unassigned_product_revenue - total_revenue) <= TOLERANCE}

    region_agg = aggregate(region_join[region_join[region_dim_key].notna()], region_dim_key)
    # Prefer an explicit region attribute over city/state when several labels tie semantically.
    region_label = next((column for column in ("region", "name", "state", "city") if column in region.columns and column != region_dim_key), None) or _semantic_column(list(region.columns), ("region", "name", "state", "city"), {region_dim_key}) or region_dim_key
    labels = region_join.groupby(region_dim_key, dropna=False, sort=True)[region_label].first().reset_index(name="region")
    region_agg = region_agg.merge(labels, on=region_dim_key, how="left").sort_values(["profit", region_dim_key], ascending=[False, True], kind="mergesort").reset_index(drop=True)
    region_agg.insert(0, "rank", range(1, len(region_agg) + 1))
    region_reconciliation = {"clean_fact_revenue": total_revenue, "assigned_region_revenue": float(region_agg["revenue"].sum()), "unassigned_region_revenue": total_revenue - float(region_agg["revenue"].sum()), "clean_fact_profit": float(_num(fact, profit).sum()), "assigned_region_profit": float(region_agg["profit"].sum()), "unassigned_region_profit": float(_num(fact, profit).sum()) - float(region_agg["profit"].sum())}
    region_reconciliation["reconciles"] = abs(region_reconciliation["assigned_region_revenue"] + region_reconciliation["unassigned_region_revenue"] - total_revenue) <= TOLERANCE and abs(region_reconciliation["assigned_region_profit"] + region_reconciliation["unassigned_region_profit"] - float(_num(fact, profit).sum())) <= TOLERANCE

    parsed_column = next((column for column in fact.columns if column.endswith("_parsed")), None)
    status_column = next((column for column in fact.columns if column.endswith("_status")), None)
    parsed = pd.to_datetime(fact[parsed_column], errors="coerce") if parsed_column else pd.Series(pd.NaT, index=fact.index)
    valid_dates = fact[status_column].astype(str).eq("VALID") & parsed.notna() if status_column else parsed.notna()
    monthly_source = fact.loc[valid_dates].copy()
    monthly_source["__date"] = parsed.loc[valid_dates].dt.normalize()
    monthly_source["__year"] = monthly_source["__date"].dt.year
    monthly_source["__month"] = monthly_source["__date"].dt.month
    monthly = monthly_source.groupby(["__year", "__month"], sort=True).agg(revenue=(revenue, "sum"), profit=(profit, "sum"), order_count=(revenue, "size")).reset_index()
    monthly["month_name"] = pd.to_datetime(monthly["__month"], format="%m").dt.month_name()
    monthly["month_key"] = monthly["__year"].astype(str) + "-" + monthly["__month"].astype(str).str.zfill(2)
    monthly["profit_margin"] = _margin(monthly["profit"], monthly["revenue"])
    monthly["revenue_change_pct"] = monthly["revenue"].pct_change() * 100
    monthly["profit_change_pct"] = monthly["profit"].pct_change() * 100
    monthly = monthly.rename(columns={"__year": "year", "__month": "month"})[["year", "month", "month_name", "month_key", "revenue", "profit", "profit_margin", "order_count", "revenue_change_pct", "profit_change_pct"]]
    valid_revenue = float(_num(fact.loc[valid_dates], revenue).sum())
    valid_profit = float(_num(fact.loc[valid_dates], profit).sum())
    monthly_reconciliation = {"clean_fact_revenue": total_revenue, "valid_date_revenue": valid_revenue, "invalid_date_revenue_excluded": total_revenue - valid_revenue, "clean_fact_profit": float(_num(fact, profit).sum()), "valid_date_profit": valid_profit, "invalid_date_profit_excluded": float(_num(fact, profit).sum()) - valid_profit, "monthly_revenue": float(monthly["revenue"].sum()), "monthly_profit": float(monthly["profit"].sum()), "reconciles": abs(float(monthly["revenue"].sum()) - valid_revenue) <= TOLERANCE and abs(float(monthly["profit"].sum()) - valid_profit) <= TOLERANCE}

    product_agg["profit_margin"] = product_agg["profit_margin"].fillna(0)
    high_threshold = float(product_agg["revenue"].quantile(HIGH_REVENUE_QUANTILE))
    low_threshold = float(product_agg["profit_margin"].quantile(LOW_MARGIN_QUANTILE))
    watch = product_agg[(product_agg["revenue"] >= high_threshold) & (product_agg["profit_margin"] <= low_threshold)].copy()
    watch["high_revenue_threshold"] = high_threshold
    watch["low_margin_threshold"] = low_threshold
    watch["reason_flagged"] = "Revenue is at or above the 75th percentile and aggregate profit margin is at or below the 25th percentile."
    watch = watch.sort_values(["revenue", product_dim_key], ascending=[False, True], kind="mergesort")

    total_profit = float(_num(fact, profit).sum())
    kpis = {"total_revenue": total_revenue, "total_profit": total_profit, "profit_margin": total_profit / total_revenue if total_revenue else None, "clean_orders_events": int(len(fact)), "distinct_valid_customers": int(fact[customer_key].dropna().map(_norm).nunique()) if customer_key else None, "distinct_valid_products": int(fact[product_key].dropna().map(_norm).nunique())}
    if "is_return" in fact:
        kpis["return_rows"] = int(fact["is_return"].eq(True).sum())
        kpis["return_rate"] = kpis["return_rows"] / len(fact) if len(fact) else None

    leader = top_products.iloc[0]["product"] if not top_products.empty and "product" in top_products else "none"
    profit_region = region_agg.iloc[0]["region"] if not region_agg.empty else "none"
    best_month = monthly.loc[monthly["revenue"].idxmax(), "month_key"] if not monthly.empty else "none"
    return {
        "success": True, "status": "READY", "analysis_summary": {"revenue_leader": f"{leader} leads named products by observed revenue.", "profit_leader": f"{profit_region} has the highest observed regional profit.", "monthly_trend": f"{best_month} is the highest-revenue valid-date month." if best_month != "none" else "No valid-date months were available.", "margin_watchlist": f"{len(watch)} products meet the transparent high-revenue / low-margin rule."},
        "kpis": kpis,
        "measure_semantics": {"revenue": revenue, "profit": profit, "profit_derived_from_revenue_minus_cost": derived_profit, "cost": cost},
        "top_products_by_revenue": {"question": "Which products lead revenue?", "method": "Aggregate cleaned fact revenue by validated product key and sort revenue descending with key tie-breaker.", "rows": _rows(top_products), "displayed_rows": int(len(top_products)), "reconciliation": product_reconciliation, "interpretation": f"{leader} is the leading named product by observed revenue.", "caveat": "Null or orphan product keys are excluded from named rankings and reconciled as unassigned."},
        "regional_profit": {"question": "Which regions have the highest profit?", "method": "Aggregate cleaned fact profit by validated region key and sort profit descending with key tie-breaker.", "rows": _rows(region_agg), "reconciliation": region_reconciliation, "interpretation": f"{profit_region} has the highest observed regional profit.", "caveat": "No causal explanation is inferred from the aggregate ranking."},
        "monthly_performance": {"question": "How do revenue and profit vary by month?", "method": "Join only valid cleaned fact dates to dim_date and aggregate chronologically by year and month.", "rows": _rows(monthly), "reconciliation": monthly_reconciliation, "interpretation": f"Monthly analysis uses {int(valid_dates.sum())} valid-date fact rows and excludes {int((~valid_dates).sum())} unresolved-date rows.", "caveat": "Invalid or unresolved dates remain in overall KPIs but are excluded from time trends."},
        "high_revenue_low_profit_margin_products": {"question": "Which products are high revenue but low margin?", "method": "Flag products at or above the 75th revenue percentile and at or below the 25th aggregate-margin percentile.", "high_revenue_quantile": HIGH_REVENUE_QUANTILE, "low_margin_quantile": LOW_MARGIN_QUANTILE, "high_revenue_threshold": high_threshold, "low_margin_threshold": low_threshold, "rows": _rows(watch), "interpretation": "These are margin-efficiency watchlist items, not judgments that products are bad.", "caveat": "Margins are aggregate profit divided by aggregate revenue; zero-revenue margins are treated as unavailable."},
        "reconciliation": {"total_clean_fact_revenue": total_revenue, "total_clean_fact_profit": total_profit, "product": product_reconciliation, "region": region_reconciliation, "monthly": monthly_reconciliation, "all_reconciled": bool(product_reconciliation["reconciles"] and monthly_reconciliation["reconciles"])},
        "caveats": [f"{int((~valid_dates).sum())} fact rows with invalid or unresolved dates are excluded from monthly analysis.", f"{product_rel['null_fk_rows']} null and {product_rel['orphan_fk_rows']} orphan product FK rows are excluded from named product rankings.", f"{region_rel['null_fk_rows']} null and {region_rel['orphan_fk_rows']} orphan region FK rows are excluded from regional rankings.", "Prompt 3 category/sub-category review items remain visible; product-key calculations are not altered.", "All interpretations describe observed associations and do not claim causality."],
        "relationships": {"product": product_rel, "region": region_rel},
        "model_used": ["fact_orders", "dim_customer", "dim_product", "dim_date", "dim_region"],
        "read_only": True,
    }
