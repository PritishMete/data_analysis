import pandas as pd

from common.detail_analysis import analyze_dataset_collection
from common.detail_report import render_detail_report


def test_detail_analysis_proposes_fact_dimensions_and_relationships():
    tables = {
        "orders": pd.DataFrame({
            "OrderID": [1, 2, 3],
            "CustomerID": [10, 11, 10],
            "Revenue": [100, 200, 50],
        }),
        "customers": pd.DataFrame({
            "CustomerID": [10, 11, 12],
            "CustomerName": ["A", "B", "C"],
        }),
    }

    result = analyze_dataset_collection(tables)

    assert result["dataset_count"] == 2
    assert "orders" in result["model_recommendation"]["fact_tables"]
    assert "customers" in result["model_recommendation"]["dimension_tables"]
    assert any(
        relationship["source_table"] == "orders"
        and relationship["target_table"] == "customers"
        and relationship["source_column"] == "CustomerID"
        for relationship in result["relationships"]
    )
    star = result["star_schema"]
    assert star["fact_tables"][0]["source_table"] == "orders"
    assert {item["source_table"] for item in star["dimensions"]} == {"customers"}
    assert star["relationships"][0]["cardinality"] == "one_to_many"
    assert star["relationships"][0]["target_key_unique"] is True


def test_detail_analysis_reports_semantic_types_quality_and_evidence_backed_categories():
    tables = {
        "orders": pd.DataFrame({
            "order_id": ["O1", "O2", "O2"],
            "order_date": ["2025-01-01", "not_a_date", "2025-01-03"],
            "customer_id": ["C1", None, "C1"],
            "product_id": ["P1", "P2", None],
            "region_id": ["R1", "R1", "R1"],
            "quantity": [2, -1, 1],
            "discount": [0.1, 0.0, 0.0],
            "sales_amount": [18.0, -5.0, 10.0],
            "cost_amount": [10.0, 4.0, 5.0],
            "profit": [8.0, -1.0, 5.0],
        }),
        "customers": pd.DataFrame({
            "customer_id": ["C1", "C1"],
            "customer_name": ["A", "A"],
        }),
        "products": pd.DataFrame({
            "product_id": ["P1", "P2", "P3", "P4", "P5"],
            "category": ["Electronics", "electronics", "Furniture", "Furniture", "Furniture "],
            "sub_category": ["Laptops", "Laptops", "Laptops", "Chairs", "Chairs"],
            "cost": [5.0] * 5,
            "selling_price": [10.0] * 5,
        }),
        "regions": pd.DataFrame({
            "region_id": ["R1"],
            "region": ["North"],
        }),
    }

    result = analyze_dataset_collection(tables)
    profiles = {item["name"]: item["profile"] for item in result["datasets"]}
    order_schema = {item["column"]: item for item in profiles["orders"]["schema"]}

    assert order_schema["order_date"]["physical_dtype"] == "text"
    assert order_schema["order_date"]["logical_type"] == "datetime"
    assert order_schema["quantity"]["logical_type"] == "integer"
    assert profiles["customers"]["primary_key_candidates"] == []
    assert profiles["customers"]["business_key_candidates"] == ["customer_id"]

    customer_relation = next(r for r in result["relationships"] if r["target_table"] == "customers")
    assert customer_relation["source_nulls"] == 1
    assert customer_relation["orphan_rows"] == 0
    assert customer_relation["non_null_referential_coverage"] == 1.0
    assert customer_relation["cardinality"] == "many_to_many_or_non_unique_target"

    category_issue = result["detail_report"]["category_mismatches"]
    assert len(category_issue) == 1
    assert "1 row(s)" in category_issue[0]
    assert any("Furniture" in item for item in result["detail_report"]["inconsistencies"])
    assert result["detail_report"]["issue_register"]
    assert any("duplicate candidate-key" in row[4] for row in result["detail_report"]["issue_register"])


def test_detail_report_renders_dynamic_fact_center_and_relationship_warnings():
    result = analyze_dataset_collection({
        "orders": pd.DataFrame({
            "order_id": ["O1", "O2", "O3"],
            "customer_id": ["C1", "C1", "C2"],
            "product_id": ["P1", "P1", "P2"],
            "region_id": ["R1", "R1", "R2"],
            "quantity": [1, 2, 1],
            "sales_amount": [10, 20, 12],
        }),
        "customers": pd.DataFrame({
            "customer_id": ["C1", "C1", "C2"],
            "customer_name": ["A", "A duplicate", "B"],
        }),
        "products": pd.DataFrame({
            "product_id": ["P1", "P2"],
            "product_name": ["Widget", "Gadget"],
        }),
        "regions": pd.DataFrame({
            "region_id": ["R1", "R2"],
            "region_name": ["North", "South"],
        }),
    })

    html = render_detail_report(result)
    assert "class='star-schema-links'" in html
    assert "class='star-center star-node' style='left:50%;top:50%;'" in html
    assert html.count("class='star-dimension star-node") >= 3
    assert "1 -&gt; many" in html or "1 -> many" in html
    assert "Non-unique target key" in html
    assert "key cleanup required" in html
    assert html.count("Non-unique target key") == 1
    assert html.count("schema-link-warning") == 1
