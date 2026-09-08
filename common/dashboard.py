"""Deterministic Chapter 7 dashboard calculations over the cleaned model."""

from __future__ import annotations

from typing import Any

import pandas as pd

from .business_analysis import TOLERANCE, _join_dimension, _margin, _measure_columns, _norm, _num, _rows, _semantic_column


def build_dashboard(model: dict[str, Any], filters: dict[str, Any] | None = None) -> dict[str, Any]:
    required = {"fact_orders", "dim_customer", "dim_product", "dim_date", "dim_region"}
    if not required.issubset(model):
        return {"success": False, "status": "BLOCKED", "error": "Clean analytical model is required before the dashboard."}
    fact = pd.DataFrame(model["fact_orders"].get("rows", []), columns=model["fact_orders"].get("columns", []))
    customer = pd.DataFrame(model["dim_customer"].get("rows", []), columns=model["dim_customer"].get("columns", []))
    product = pd.DataFrame(model["dim_product"].get("rows", []), columns=model["dim_product"].get("columns", []))
    region = pd.DataFrame(model["dim_region"].get("rows", []), columns=model["dim_region"].get("columns", []))
    if fact.empty or product.empty or region.empty:
        return {"success": False, "status": "BLOCKED", "error": "Clean analytical model is incomplete for the dashboard."}
    metadata = model.get("fact_metadata", {})
    event_key = metadata.get("event_key") or _semantic_column(list(fact.columns), ("order", "transaction", "event", "invoice"))
    measures = _measure_columns(fact, event_key)
    revenue = _semantic_column(measures, ("revenue", "sales", "amount"))
    profit = _semantic_column(measures, ("profit",))
    cost = _semantic_column(measures, ("cost",))
    if not revenue:
        return {"success": False, "status": "BLOCKED", "error": "No revenue measure is available in the cleaned fact."}
    if not profit and cost:
        profit = "__derived_profit"
        fact[profit] = _num(fact, revenue) - _num(fact, cost)
    if not profit:
        return {"success": False, "status": "BLOCKED", "error": "No profit measure is available in the cleaned fact."}

    product_key = metadata.get("product_key") or _semantic_column(list(fact.columns), ("product", "item", "sku"))
    region_key = metadata.get("region_key") or _semantic_column(list(fact.columns), ("region", "geography", "area"))
    customer_key = metadata.get("customer_key") or _semantic_column(list(fact.columns), ("customer", "client", "member"))
    product_dim_key = product_key if product_key in product.columns else _semantic_column(list(product.columns), ("product", "item", "sku"))
    region_dim_key = region_key if region_key in region.columns else _semantic_column(list(region.columns), ("region", "geography", "area"))
    if not product_key or not product_dim_key or not region_key or not region_dim_key:
        return {"success": False, "status": "BLOCKED", "error": "Validated product and region relationships are required for the dashboard."}

    product_join, product_rel = _join_dimension(fact, product_key, product, product_dim_key, "product")
    region_join, region_rel = _join_dimension(fact, region_key, region, region_dim_key, "region")
    product_label = _semantic_column(list(product.columns), ("name", "description", "label"), {product_dim_key}) or product_dim_key
    category = _semantic_column(list(product.columns), ("category",))
    # An explicit business-region field wins over city/state display attributes.
    region_label = next((column for column in region.columns if column.casefold() == "region" and column != region_dim_key), None) or _semantic_column(list(region.columns), ("region", "name", "state", "city"), {region_dim_key}) or region_dim_key
    parsed_column = next((column for column in fact.columns if column.endswith("_parsed")), None)
    status_column = next((column for column in fact.columns if column.endswith("_status")), None)
    parsed = pd.to_datetime(fact[parsed_column], errors="coerce") if parsed_column else pd.Series(pd.NaT, index=fact.index)
    valid_dates = fact[status_column].astype(str).eq("VALID") & parsed.notna() if status_column else parsed.notna()

    raw_filters = filters or {}
    selected_year = int(raw_filters["year"]) if raw_filters.get("year") not in (None, "", "All") else None
    selected_region = str(raw_filters["region"]) if raw_filters.get("region") not in (None, "", "All") else None
    selected_category = str(raw_filters["category"]) if raw_filters.get("category") not in (None, "", "All") else None
    context = pd.Series(True, index=fact.index)
    if selected_year is not None:
        context &= valid_dates & parsed.dt.year.eq(selected_year)
    if selected_region is not None:
        context &= region_join[region_label].map(_norm).eq(_norm(selected_region))
    if selected_category is not None:
        context &= product_join[category].map(_norm).eq(_norm(selected_category)) if category else False
    filtered = fact.loc[context].copy()
    filtered_product = product_join.loc[context].copy()
    filtered_region = region_join.loc[context].copy()
    total_revenue = float(_num(filtered, revenue).sum())
    total_profit = float(_num(filtered, profit).sum())
    orders = int(len(filtered))
    customer_count = int(filtered[customer_key].dropna().map(_norm).nunique()) if customer_key else None
    return_rows = int(filtered["is_return"].eq(True).sum()) if "is_return" in filtered else None
    valid_context_dates = context & valid_dates
    date_filtered = fact.loc[valid_context_dates].copy()
    date_filtered["__date"] = parsed.loc[valid_context_dates].dt.normalize()
    date_filtered["__year"] = date_filtered["__date"].dt.year
    date_filtered["__month"] = date_filtered["__date"].dt.month
    monthly = date_filtered.groupby(["__year", "__month"], sort=True).agg(revenue=(revenue, "sum"), profit=(profit, "sum"), orders=(revenue, "size")).reset_index()
    if not monthly.empty:
        monthly["month_name"] = pd.to_datetime(monthly["__month"], format="%m").dt.month_name()
        monthly["month_key"] = monthly["__year"].astype(str) + "-" + monthly["__month"].astype(str).str.zfill(2)
        monthly["profit_margin"] = _margin(monthly["profit"], monthly["revenue"])
    else:
        monthly = pd.DataFrame(columns=["__year", "__month", "month_name", "month_key", "revenue", "profit", "orders", "profit_margin"])
    named_product = filtered_product[filtered_product[product_label].notna()].copy()
    product_group = named_product.groupby(product_dim_key, sort=True).agg(revenue=(revenue, "sum"), profit=(profit, "sum"), orders=(revenue, "size")).reset_index()
    product_group["profit_margin"] = _margin(product_group["profit"], product_group["revenue"])
    product_group = product_group.merge(named_product.groupby(product_dim_key, sort=True)[product_label].first().reset_index(name="product"), on=product_dim_key, how="left")
    if category:
        product_group = product_group.merge(named_product.groupby(product_dim_key, sort=True)[category].first().reset_index(name="category"), on=product_dim_key, how="left")
    product_group = product_group.sort_values(["revenue", product_dim_key], ascending=[False, True], kind="mergesort").reset_index(drop=True)
    product_group.insert(0, "rank", range(1, len(product_group) + 1))
    region_named = filtered_region[filtered_region[region_label].notna()].copy()
    region_group = region_named.assign(__region_display=region_named[region_label].map(lambda value: str(value).strip())).groupby("__region_display", sort=True).agg(revenue=(revenue, "sum"), profit=(profit, "sum"), orders=(revenue, "size")).reset_index().rename(columns={"__region_display": "region"})
    region_group["profit_margin"] = _margin(region_group["profit"], region_group["revenue"])
    region_group = region_group.sort_values(["profit", "region"], ascending=[False, True], kind="mergesort").reset_index(drop=True)
    region_group.insert(0, "rank", range(1, len(region_group) + 1))
    product_named_revenue = float(product_group["revenue"].sum())
    region_named_revenue = float(region_group["revenue"].sum())
    region_named_profit = float(region_group["profit"].sum())
    available_years = sorted({int(value) for value in parsed.loc[valid_dates].dt.year.dropna().unique()})
    available_regions = sorted({str(value).strip() for value in region[region_label].dropna().tolist()})
    available_categories = sorted({str(value).strip() for value in product[category].dropna().tolist()}) if category else []
    empty = filtered.empty
    return {
        "success": True, "status": "READY", "dashboard_metadata": {"title": "Vibe Analysis - Sales Performance Dashboard", "model": ["fact_orders", "dim_customer", "dim_product", "dim_date", "dim_region"], "region_field": region_label, "region_grain": "Business region display label; region keys sharing a label are intentionally aggregated."},
        "available_filters": {"year": available_years, "region": available_regions, "category": available_categories},
        "active_filters": {"year": selected_year, "region": selected_region, "category": selected_category},
        "filter_summary": "All data" if not any((selected_year, selected_region, selected_category)) else "Showing: " + " • ".join(str(value) for value in (selected_year or "All", selected_region or "All", selected_category or "All")),
        "empty": empty,
        "kpis": {"revenue": total_revenue, "profit": total_profit, "orders": orders, "customers": customer_count or 0, "profit_margin": total_profit / total_revenue if total_revenue else None, "return_rate": return_rows / orders if return_rows is not None and orders else None},
        "monthly_trend": _rows(monthly.rename(columns={"__year": "year", "__month": "month"})),
        "revenue_by_category": _rows(product_group.groupby("category", dropna=False, sort=True).agg(revenue=("revenue", "sum"), profit=("profit", "sum"), orders=("orders", "sum")).reset_index().sort_values(["revenue", "category"], ascending=[False, True], kind="mergesort")) if category else [],
        "profit_by_region": _rows(region_group),
        "top_products": _rows(product_group.head(10)),
        "reconciliation": {"filtered_fact_rows": orders, "filtered_revenue": total_revenue, "filtered_profit": total_profit, "unassigned_product_revenue": total_revenue - product_named_revenue, "unassigned_region_revenue": total_revenue - region_named_revenue, "unassigned_region_profit": total_profit - region_named_profit, "valid_date_revenue": float(_num(date_filtered, revenue).sum()), "valid_date_profit": float(_num(date_filtered, profit).sum()), "monthly_revenue": float(monthly["revenue"].sum()), "monthly_profit": float(monthly["profit"].sum()), "all_reconciled": abs(float(monthly["revenue"].sum()) - float(_num(date_filtered, revenue).sum())) <= TOLERANCE and abs(float(monthly["profit"].sum()) - float(_num(date_filtered, profit).sum())) <= TOLERANCE and abs(product_named_revenue + (total_revenue - product_named_revenue) - total_revenue) <= TOLERANCE and abs(region_named_profit + (total_profit - region_named_profit) - total_profit) <= TOLERANCE},
        "insights": {"top_product": product_group.iloc[0]["product"] if not product_group.empty else None, "highest_profit_region": region_group.iloc[0]["region"] if not region_group.empty else None, "best_revenue_month": monthly.loc[monthly["revenue"].idxmax(), "month_key"] if not monthly.empty else None},
        "caveats": ["Invalid or unresolved dates are excluded from the monthly trend." if (~valid_dates & context).any() else "No invalid dates in the active context.", "Missing or orphan product keys are retained in KPI totals and shown as unassigned reconciliation revenue.", "Missing or orphan region keys are retained in KPI totals and shown as unassigned reconciliation values."],
        "read_only": True,
    }


def build_dashboard_from_tables(tables: dict[str, pd.DataFrame], filters: dict[str, Any] | None = None, source_hashes: dict[str, str] | None = None) -> dict[str, Any]:
    from .customer_cleaning import clean_customer_dimension
    from .date_dimension import create_date_dimension
    from .order_cleaning import clean_order_fact
    from .product_cleaning import clean_product_dimension

    fact_result = clean_order_fact(tables, source_hashes=source_hashes)
    if fact_result.get("status") == "BLOCKED":
        return {"success": False, "status": "BLOCKED", "error": "Clean analytical model is required before the dashboard."}
    customer_result = clean_customer_dimension(tables)
    product_result = clean_product_dimension(tables)
    date_result = create_date_dimension(fact_result)
    if date_result.get("status") == "BLOCKED":
        return {"success": False, "status": "BLOCKED", "error": "Clean dim_date is required before the dashboard."}
    region_name = next((name for name in tables if "region" in name.casefold()), None)
    if not region_name:
        return {"success": False, "status": "BLOCKED", "error": "A validated region dimension is required before the dashboard."}
    region = tables[region_name]
    model = {"fact_orders": fact_result["cleaned_table"], "dim_customer": customer_result["cleaned_table"], "dim_product": product_result["cleaned_table"], "dim_date": date_result["cleaned_table"], "dim_region": {"name": "dim_region", "columns": [str(column) for column in region.columns], "rows": _rows(region)}, "fact_metadata": {"event_key": fact_result.get("event_key", {}).get("column"), "customer_key": next((item["source_column"] for item in fact_result.get("relationships", []) if item["target_table"] == "dim_customer"), None), "product_key": next((item["source_column"] for item in fact_result.get("relationships", []) if item["target_table"] == "dim_product"), None), "region_key": next((item["source_column"] for item in fact_result.get("relationships", []) if item["target_table"] == region_name), None)}}
    result = build_dashboard(model, filters)
    result["source_hashes"] = source_hashes or {}
    result["model_state"] = ["dim_customer", "dim_product", "dim_date", "dim_region", "fact_orders"]
    return result
