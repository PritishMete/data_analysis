import pandas as pd

from common.data_understanding import profile_dataframe


def test_profile_describes_schema_keys_and_quality_signals():
    df = pd.DataFrame({
        "OrderID": [1, 2, 3],
        "CustomerID": [10, 10, 11],
        "Region": ["North", "north ", None],
        "Revenue": [100.0, -5.0, 20.0],
        "ReviewText": ["good", "needs work", "fine"],
    })

    profile = profile_dataframe(df)

    assert profile["dataset_overview"]["rows"] == 3
    assert profile["dataset_overview"]["columns"] == 5
    assert "OrderID" in profile["primary_key_candidates"]
    assert "CustomerID" in profile["foreign_key_candidates"]
    assert any(item["column"] == "Region" for item in profile["categorical_inconsistencies"])
    assert any(item["column"] == "Revenue" for item in profile["invalid_or_suspicious_values"])
    roles = {item["column"]: item["role"] for item in profile["schema"]}
    assert roles["ReviewText"] == "free_text"
    assert roles["Revenue"] == "numeric_measure"
