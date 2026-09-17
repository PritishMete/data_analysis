import pandas as pd
import pytest
from fastapi.testclient import TestClient

from main import app

from secure_excel.executor import execute_structured_query
from secure_excel.query_parser import parse_query
from secure_excel.query_validator import ValidationError, validate_structured_query
from secure_excel.semantic_roles import build_schema_profile


def _schema(df: pd.DataFrame):
    return build_schema_profile(df)


def test_restaurant_count_by_city_is_generic_group_count():
    df = pd.DataFrame(
        {
            "Restaurant ID": [1, 2, 3, 4],
            "City": ["Delhi", "Delhi", "Mumbai", "Kolkata"],
            "Restaurant Name": ["A", "B", "C", "D"],
        }
    )
    schema = _schema(df)
    query = parse_query("Show the number of restaurants in each city", schema)
    validated = validate_structured_query(query, schema)
    result = execute_structured_query(df, schema, validated)

    assert validated["operation"] == "group"
    assert validated["group_by"] == [schema["role_index"]["geographic_area"][0]]
    assert {row["City"]: row["count"] for row in result["result"]["rows"]} == {
        "Delhi": 2,
        "Mumbai": 1,
        "Kolkata": 1,
    }


def test_restaurant_count_by_city_serializes_blank_city_as_null():
    df = pd.DataFrame(
        {
            "Restaurant ID": [1, 2, 3, 4],
            "City": ["Delhi", None, "Mumbai", "Kolkata"],
            "Restaurant Name": ["A", "B", "C", "D"],
        }
    )
    schema = _schema(df)
    query = validate_structured_query(
        parse_query("Show the number of restaurants in each city", schema),
        schema,
    )
    result = execute_structured_query(df, schema, query)

    rows = result["result"]["rows"]
    assert any(row["City"] is None and row["count"] == 1 for row in rows)


def test_excel_query_api_handles_group_count_and_quality_check_without_remote_cleaning(tmp_path):
    workbook = tmp_path / "restaurants.xlsx"
    pd.DataFrame(
        {
            "Restaurant ID": [101, 102, 102, 103],
            "City": ["Delhi", None, "Mumbai", "Kolkata"],
            "Restaurant Name": ["A", "B", "C", "D"],
        }
    ).to_excel(workbook, sheet_name="Restaurants", index=False)

    client = TestClient(app)
    with workbook.open("rb") as handle:
        session_response = client.post(
            "/excel/session",
            data={"sheet_name": "Restaurants"},
            files={
                "file": (
                    "restaurants.xlsx",
                    handle,
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                )
            },
        )
    assert session_response.status_code == 200
    session_id = session_response.json()["session_id"]

    count_response = client.post(
        "/excel/query",
        data={
            "session_id": session_id,
            "text": "Show the number of restaurants in each city",
        },
    )
    assert count_response.status_code == 200
    count_body = count_response.json()
    assert count_body["query"]["operation"] == "group"
    assert any(
        row["City"] is None and row["count"] == 1
        for row in count_body["result"]["rows"]
    )

    quality_response = client.post(
        "/excel/query",
        data={
            "session_id": session_id,
            "text": "Check for missing values and duplicate restaurant IDs",
        },
    )
    assert quality_response.status_code == 200
    quality_body = quality_response.json()
    assert quality_body["query"]["operation"] == "quality_check"
    assert quality_body["result"]["missing_by_column"] == {"City": 1}
    assert quality_body["result"]["duplicate_identifier"]["duplicate_row_count"] == 2
    assert quality_body["result"]["source_mutated"] is False


@pytest.mark.parametrize(
    "text",
    [
        "Count restaurants per city",
        "How many restaurants are there by city?",
        "Group restaurants by city and count them",
    ],
)
def test_group_count_variations_are_not_hardcoded_to_one_sentence(text):
    df = pd.DataFrame({"City": ["Delhi", "Delhi", "Mumbai"], "Name": ["A", "B", "C"]})
    schema = _schema(df)
    query = validate_structured_query(parse_query(text, schema), schema)
    result = execute_structured_query(df, schema, query)

    assert query["operation"] == "group"
    assert result["result"]["row_count"] == 2
    assert sorted(row["count"] for row in result["result"]["rows"]) == [1, 2]


def test_read_only_quality_check_reports_missing_values_and_duplicate_ids_without_mutation():
    df = pd.DataFrame(
        {
            "Restaurant ID": [101, 102, 102, 103],
            "City": ["Delhi", None, "Mumbai", "Kolkata"],
            "Name": ["A", "B", "C", "D"],
        }
    )
    original = df.copy(deep=True)
    schema = _schema(df)
    query = validate_structured_query(
        parse_query("Check for missing values and duplicate restaurant IDs", schema),
        schema,
    )
    result = execute_structured_query(df, schema, query)

    assert query["operation"] == "quality_check"
    assert result["result"]["missing_by_column"] == {"City": 1}
    duplicate = result["result"]["duplicate_identifier"]
    assert duplicate["status"] == "ok"
    assert duplicate["column"] == "Restaurant ID"
    assert duplicate["duplicate_value_count"] == 1
    assert duplicate["duplicate_row_count"] == 2
    assert duplicate["values"] == [102]
    assert result["result"]["source_mutated"] is False
    pd.testing.assert_frame_equal(df, original)


def test_quality_check_requires_explicit_identifier_when_multiple_identifiers_exist():
    df = pd.DataFrame(
        {
            "Restaurant ID": [1, 2],
            "Outlet ID": [10, 11],
            "City": ["Delhi", "Mumbai"],
        }
    )
    schema = _schema(df)
    parsed = parse_query("Check missing values and duplicate IDs", schema)
    assert parsed["operation"] == "quality_check"
    assert parsed["identifier_column_id"] is None
    assert parsed["report"] == "data_quality_ambiguous_identifier"
    validated = validate_structured_query(parsed, schema)
    assert validated["report"] == "data_quality_ambiguous_identifier"


def test_quality_check_does_not_invoke_cleaning_operation():
    df = pd.DataFrame({"Restaurant ID": [1, 1], "City": ["Delhi", None]})
    schema = _schema(df)
    query = validate_structured_query(
        parse_query("Check for missing values and duplicate restaurant IDs", schema),
        schema,
    )
    assert query["operation"] == "quality_check"
    assert query["operation"] not in {"clean", "clean_data", "remove_duplicates"}
