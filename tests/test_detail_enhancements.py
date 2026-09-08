import pandas as pd

from common.data_understanding import profile_dataframe
from common.detail_enhancements import date_profiles, duplicate_analysis, kpi_readiness, numeric_profiles
from common.customer_cleaning import clean_customer_dimension
from common.product_cleaning import clean_product_dimension
from common.order_cleaning import clean_order_fact
from common.date_dimension import create_date_dimension
from common.business_analysis import analyze_clean_model
from common.dashboard import build_dashboard


def _tables():
    return {
        "sales": pd.DataFrame({
            "event_id": [1, 1, 2, 3, 3],
            "amount": [10.0, 10.0, 20.0, 5.0, 6.0],
            "event_date": ["2025-01-01", "2025-01-01", "2025-01-03", "bad", None],
        }),
        "customers": pd.DataFrame({
            "customer_id": ["C1", "C1", "C2"],
            "segment": ["A", "B", "A"],
        }),
    }


def test_duplicate_classification_separates_exact_identical_and_conflicting_keys():
    tables = _tables()
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    result = duplicate_analysis(tables, profiles, ["sales"], ["customers"])

    assert result["duplicate_analysis"]["sales"]["exact_duplicate_rows"] == 1
    assert result["duplicate_analysis"]["sales"]["duplicate_key_groups"] == 2
    assert result["duplicate_analysis"]["sales"]["identical_duplicate_key_groups"] == 1
    assert result["duplicate_analysis"]["sales"]["conflicting_duplicate_key_groups"] == 1
    assert result["duplicate_analysis"]["customers"]["conflicting_duplicate_key_groups"] == 1


def test_numeric_profiles_exclude_identifier_and_calculate_iqr():
    tables = {"sales": _tables()["sales"]}
    profiles = {"sales": profile_dataframe(tables["sales"])}
    result = numeric_profiles(tables, profiles)["sales"]

    assert {item["column"] for item in result} == {"amount"}
    amount = result[0]
    assert amount["valid_count"] == 5
    assert amount["iqr"] >= 0
    assert "Statistical observation" in amount["interpretation"]


def test_date_profiles_keep_malformed_and_no_record_dates_separate():
    tables = _tables()
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    item = date_profiles(tables, profiles)["sales"][0]

    assert item["valid_count"] == 3
    assert item["invalid_count"] == 1
    assert item["null_count"] == 1
    assert item["no_record_date_count"] == 1
    assert item["freshness_status"] == "INSUFFICIENT EVIDENCE"


def test_kpi_readiness_expresses_duplicate_and_business_rule_caveats():
    tables = _tables()
    profiles = {name: profile_dataframe(frame) for name, frame in tables.items()}
    duplicates = duplicate_analysis(tables, profiles, ["sales"], ["customers"])
    relationships = [{"source_table": "sales", "source_column": "customer_id", "target_table": "customers", "target_column": "customer_id", "target_unique": False}]
    tables["sales"]["customer_id"] = ["C1", "C1", "C2", "C1", "C2"]
    profiles["sales"] = profile_dataframe(tables["sales"])
    result = kpi_readiness(tables, profiles, ["sales"], ["customers"], duplicates, relationships)

    assert any(item["readiness"] == "READY WITH CAVEAT" for item in result)


def test_customer_cleaning_collapses_safe_duplicates_without_mutating_source():
    source = pd.DataFrame({"customer_id": ["C1", "C1", "C2"], "name": ["A", "A", "B"]})
    before = source.copy(deep=True)
    result = clean_customer_dimension({"customer_export": source})

    assert result["dimension_name"] == "dim_customer"
    assert result["summary"]["clean_rows"] == 2
    assert result["summary"]["final_duplicate_key_groups"] == 0
    assert source.equals(before)
    assert result["read_only"] is True
    assert clean_customer_dimension({"customer_export": source})["cleaned_table"] == result["cleaned_table"]


def test_customer_cleaning_keeps_conflicting_keys_for_review():
    source = pd.DataFrame({"customer_id": ["C1", "C1"], "name": ["A", "B"]})
    result = clean_customer_dimension({"customers": source})

    assert result["status"] == "REQUIRES REVIEW"
    assert result["summary"]["conflicting_duplicate_key_groups"] == 1
    assert result["summary"]["requires_review"] == 1
    assert result["cleaned_table"]["rows"] == []


def test_customer_detection_prefers_plural_customer_entity_over_other_dimensions():
    tables = {
        "regions_raw": pd.DataFrame({"region_id": ["R1"], "region": ["North"]}),
        "customers_raw": pd.DataFrame({"customer_id": ["C1", "C1"], "name": ["A", "A"]}),
    }
    result = clean_customer_dimension(tables)

    assert result["source_dataset"] == "customers_raw"
    assert result["summary"]["business_key"] == "customer_id"


def test_customer_cleaning_collapses_case_and_whitespace_equivalent_keys():
    result = clean_customer_dimension({"customers": pd.DataFrame({"customer_id": [" C1 ", "c1"], "name": ["A", "A"]})})

    assert result["summary"]["clean_rows"] == 1
    assert result["summary"]["identical_duplicate_key_groups_resolved"] == 1


def test_product_cleaning_normalizes_representational_values_and_preserves_key():
    source = pd.DataFrame({
        "product_id": ["P1", "P2", "P3"],
        "category": [" Electronics ", "electronics", "Home"],
        "sub_category": ["Phones", "Phones", "Home Office"],
        "price": [10.0, 12.0, 4.0],
    })
    before = source.copy(deep=True)
    result = clean_product_dimension({"products": source})

    assert result["dimension_name"] == "dim_product"
    assert result["summary"]["clean_rows"] == 3
    assert result["summary"]["final_key_uniqueness_percent"] == 100.0
    assert result["summary"]["representation_issues_resolved"] == 1
    assert source.equals(before)
    assert clean_product_dimension({"products": source})["cleaned_table"] == result["cleaned_table"]


def test_product_cleaning_does_not_silently_resolve_ambiguous_mapping():
    source = pd.DataFrame({
        "product_id": ["P1", "P2"],
        "category": ["A", "B"],
        "sub_category": ["Shared", "Shared"],
    })
    result = clean_product_dimension({"products": source})

    assert result["status"] == "READY WITH REVIEW ITEMS"
    assert result["summary"]["category_subcategory_mismatch_rows"] == 1
    assert result["mapping_issues"][0]["status"] == "INSUFFICIENT EVIDENCE"


def _order_tables():
    return {
        "orders_export": pd.DataFrame({
            "transaction_id": ["T1", "T1", "T2", "T3", "T4", "T5", "T6"],
            "transaction_date": ["2025-01-01", "2025-01-01", "bad", None, "2025-01-03", "2025-01-04", "2025-01-05"],
            "customer_id": ["C1", "C1", "C2", None, "C9", "C1", "C1"],
            "product_id": ["P1", "P1", "P2", "P2", None, "P1", "P1"],
            "quantity": [-1, -1, 0, 2, 1, 3, 4],
            "sales": [10, 10, 20, 30, 40, 50, 60],
        }),
        "customers_export": pd.DataFrame({"customer_id": ["C1", "C2"]}),
        "products_export": pd.DataFrame({"product_id": ["P1", "P2"]}),
    }


def test_order_cleaning_removes_only_exact_duplicates_and_reconciles_measures():
    tables = _order_tables()
    before = tables["orders_export"].copy(deep=True)
    result = clean_order_fact(tables)

    assert result["fact_name"] == "fact_orders"
    assert result["summary"]["raw_rows"] == 7
    assert result["summary"]["exact_duplicates_removed"] == 1
    assert result["summary"]["clean_rows"] == 6
    assert result["summary"]["conflicting_event_key_groups"] == 0
    assert result["measure_reconciliation"]["sales"]["reconciles"] is True
    assert result["summary"]["negative_quantity_rows"] == 1
    assert result["summary"]["is_return_true"] == 1
    assert tables["orders_export"].equals(before)


def test_order_cleaning_preserves_conflicting_event_keys_and_classifies_dates_and_fks():
    tables = _order_tables()
    tables["orders_export"].loc[6, "transaction_id"] = "T2"
    result = clean_order_fact(tables)

    assert result["summary"]["conflicting_event_key_groups"] == 1
    assert result["conflicting_event_keys"][0]["outcome"] == "REQUIRES REVIEW"
    assert result["summary"]["invalid_date_rows"] == 1
    assert result["summary"]["null_date_rows"] == 1
    customer = next(item for item in result["relationships"] if item["source_column"] == "customer_id")
    assert customer["null_fk_rows"] == 1
    assert customer["orphan_fk_rows"] == 1
    assert customer["status"] == "ORPHAN_FK"
    assert len(result["cleaned_table"]["rows"]) == 6


def test_order_cleaning_is_idempotent_and_preserves_repeated_foreign_keys():
    tables = _order_tables()
    first = clean_order_fact(tables)
    cleaned = pd.DataFrame(first["cleaned_table"]["rows"])
    second = clean_order_fact({"orders_export": cleaned, "customers_export": tables["customers_export"], "products_export": tables["products_export"]})

    assert first["summary"]["clean_rows"] == 6
    assert first["summary"]["is_return_true"] == second["summary"]["is_return_true"]
    assert second["summary"]["exact_duplicates_removed"] == 0
    assert second["summary"]["clean_rows"] == 6


def test_order_cleaning_marks_non_numeric_quantity_as_unknown_return_status():
    tables = _order_tables()
    tables["orders_export"]["quantity"] = ["-1", "-1", "unknown", "0", "2", "3", "4"]
    result = clean_order_fact(tables)

    assert result["summary"]["is_return_true"] == 1
    assert result["summary"]["is_return_false"] == 4
    assert result["summary"]["is_return_unknown"] == 1


def _date_fact():
    orders = pd.DataFrame({
        "order_id": ["O1", "O2", "O3", "O4", "O5"],
        "order_date": ["2024-02-29", "2024-02-29", "bad", None, "2025-01-01"],
        "customer_id": ["C1"] * 5,
        "quantity": [1, 2, 3, 4, 5],
    })
    return clean_order_fact({"orders": orders, "customers": pd.DataFrame({"customer_id": ["C1"]})})


def test_date_dimension_uses_valid_clean_fact_dates_only_and_derives_calendar_attributes():
    result = create_date_dimension(_date_fact())

    assert result["status"] == "READY"
    assert result["summary"]["clean_fact_rows"] == 5
    assert result["summary"]["valid_fact_date_rows"] == 3
    assert result["summary"]["invalid_fact_date_rows_excluded"] == 1
    assert result["summary"]["null_fact_date_rows_excluded"] == 1
    assert result["summary"]["unique_valid_dates"] == 2
    assert [row["date_key"] for row in result["cleaned_table"]["rows"]] == [20240229, 20250101]
    assert result["cleaned_table"]["rows"][0]["month_name"] == "February"
    assert result["cleaned_table"]["rows"][0]["quarter"] == "Q1"
    assert result["relationship"]["cardinality"] == "many -> one"
    assert result["relationship"]["valid_fact_date_coverage"] == 1.0
    assert result["relationship"]["orphan_valid_fact_dates"] == 0


def test_date_dimension_is_observed_date_grain_and_idempotent():
    fact = _date_fact()
    first = create_date_dimension(fact)
    second = create_date_dimension(fact)

    assert first["grain"] == "One row per unique observed valid calendar date."
    assert first["cleaned_table"] == second["cleaned_table"]
    assert first["fact_output"]["rows"] == fact["summary"]["clean_rows"]
    assert first["validation"]["date_key_reversible"] is True


def test_date_dimension_requires_cleaned_fact_and_does_not_fallback_to_raw():
    result = create_date_dimension({"cleaned_table": {"name": "orders_raw", "rows": []}})

    assert result["status"] == "BLOCKED"
    assert "cleaned fact" in result["error"]


def _analysis_model():
    fact = pd.DataFrame({
        "order_id": ["O1", "O2", "O3", "O4", "O5"],
        "order_date_parsed": ["2025-01-01", "2025-01-01", "2025-02-01", None, "2025-02-01"],
        "order_date_status": ["VALID", "VALID", "VALID", "INVALID", "VALID"],
        "customer_id": ["C1", "C1", None, "C1", "C1"],
        "product_id": ["P1", "P2", "P1", "P9", None],
        "region_id": ["R1", "R1", "R2", "R1", "R1"],
        "quantity": [1, 2, 1, 1, 1],
        "sales": [100.0, 100.0, 20.0, 50.0, 0.0],
        "profit": [10.0, 20.0, -5.0, 5.0, 0.0],
        "is_return": [False] * 5,
    })
    return {
        "fact_orders": {"name": "fact_orders", "columns": list(fact.columns), "rows": fact.to_dict(orient="records")},
        "dim_customer": {"name": "dim_customer", "columns": ["customer_id"], "rows": [{"customer_id": "C1"}]},
        "dim_product": {"name": "dim_product", "columns": ["product_id", "product_name", "category"], "rows": [{"product_id": "P1", "product_name": "Alpha", "category": "A"}, {"product_id": "P2", "product_name": "Beta", "category": "B"}]},
        "dim_date": {"name": "dim_date", "columns": ["date_key", "date", "day", "month", "month_name", "quarter", "year"], "rows": [{"date_key": 20250101, "date": "2025-01-01", "day": 1, "month": 1, "month_name": "January", "quarter": "Q1", "year": 2025}, {"date_key": 20250201, "date": "2025-02-01", "day": 1, "month": 2, "month_name": "February", "quarter": "Q1", "year": 2025}]},
        "dim_region": {"name": "dim_region", "columns": ["region_id", "region"], "rows": [{"region_id": "R1", "region": "North"}, {"region_id": "R2", "region": "South"}]},
        "fact_metadata": {"event_key": "order_id", "customer_key": "customer_id", "product_key": "product_id", "region_key": "region_id"},
    }


def test_business_analysis_is_deterministic_and_reconciles_missing_keys_and_invalid_dates():
    first = analyze_clean_model(_analysis_model())
    second = analyze_clean_model(_analysis_model())

    assert first["status"] == "READY"
    assert first["reconciliation"]["all_reconciled"] is True
    assert first["top_products_by_revenue"]["rows"][0]["product_id"] == "P1"
    assert first["top_products_by_revenue"]["reconciliation"]["unassigned_product_revenue"] == 50.0
    assert first["monthly_performance"]["reconciliation"]["invalid_date_revenue_excluded"] == 50.0
    assert first["monthly_performance"]["rows"][0]["revenue_change_pct"] is None
    assert first["regional_profit"]["rows"][0]["region"] == "North"
    assert first["high_revenue_low_profit_margin_products"]["high_revenue_threshold"] == 115.0
    assert first["top_products_by_revenue"]["rows"] == second["top_products_by_revenue"]["rows"]


def test_business_analysis_prefers_explicit_region_label_over_city_label():
    model = _analysis_model()
    model["dim_region"] = {
        "name": "dim_region",
        "columns": ["region_id", "state", "city", "region"],
        "rows": [
            {"region_id": "R1", "state": "State A", "city": "City A", "region": "North"},
            {"region_id": "R2", "state": "State B", "city": "City B", "region": "South"},
        ],
    }
    result = analyze_clean_model(model)

    assert result["regional_profit"]["rows"][0]["region"] == "North"


def test_business_analysis_requires_complete_clean_model():
    result = analyze_clean_model({"fact_orders": {"rows": []}})

    assert result["status"] == "BLOCKED"
    assert "Clean analytical model" in result["error"]


def test_dashboard_filters_share_one_and_context_and_handle_empty_results():
    model = _analysis_model()
    all_data = build_dashboard(model)
    year = build_dashboard(model, {"year": 2025})
    region = build_dashboard(model, {"region": "North"})
    category = build_dashboard(model, {"category": "A"})
    combined = build_dashboard(model, {"year": 2025, "region": "North", "category": "A"})
    empty = build_dashboard(model, {"year": 2030})

    assert all_data["kpis"]["revenue"] == 270.0
    assert year["kpis"]["revenue"] == 220.0
    assert region["kpis"]["orders"] == 4
    assert category["kpis"]["orders"] == 2
    assert combined["kpis"]["orders"] == 1
    assert combined["reconciliation"]["all_reconciled"] is True
    assert empty["empty"] is True
    assert empty["kpis"] == {"revenue": 0.0, "profit": 0.0, "orders": 0, "customers": 0, "profit_margin": None, "return_rate": None}
    assert all_data["monthly_trend"][0]["month_key"] == "2025-01"


def test_dashboard_region_groups_display_labels_and_is_deterministic():
    model = _analysis_model()
    model["dim_region"]["rows"].append({"region_id": "R3", "region": "North"})
    model["fact_orders"]["rows"].append({**model["fact_orders"]["rows"][0], "order_id": "O6", "region_id": "R3", "sales": 5.0, "profit": 1.0})

    first = build_dashboard(model)
    second = build_dashboard(model)
    north = next(row for row in first["profit_by_region"] if row["region"] == "North")
    assert north["revenue"] == 255.0
    assert first["profit_by_region"] == second["profit_by_region"]


def test_dashboard_uses_business_region_and_resolves_all_matching_keys():
    model = _analysis_model()
    model["dim_region"] = {
        "name": "dim_region",
        "columns": ["region_id", "state", "city", "region"],
        "rows": [
            {"region_id": "R1", "state": "State A", "city": "City A", "region": "North"},
            {"region_id": "R2", "state": "State B", "city": "City B", "region": "South"},
            {"region_id": "R3", "state": "State C", "city": "City C", "region": "South"},
        ],
    }
    model["fact_orders"]["rows"].append({**model["fact_orders"]["rows"][2], "order_id": "O6", "region_id": "R3", "sales": 30.0, "profit": 7.0})

    result = build_dashboard(model)
    south = next(row for row in result["profit_by_region"] if row["region"] == "South")

    assert result["dashboard_metadata"]["region_field"] == "region"
    assert result["available_filters"]["region"] == ["North", "South"]
    assert "City B" not in result["available_filters"]["region"]
    assert south["revenue"] == 50.0
    assert south["profit"] == 2.0
    assert build_dashboard(model, {"region": "South"})["kpis"]["orders"] == 2
    assert build_dashboard(model, {"year": 2025, "region": "South", "category": "A"})["kpis"]["revenue"] == 50.0
    assert build_dashboard(model, {"region": "South"})["reconciliation"]["all_reconciled"] is True
