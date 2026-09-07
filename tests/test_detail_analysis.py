import pandas as pd

from common.detail_analysis import analyze_dataset_collection


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
