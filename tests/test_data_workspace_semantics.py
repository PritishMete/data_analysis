import pandas as pd

from schema_intelligence.semantic_engine import SemanticSchemaEngine
from schema_intelligence.semantic_query import SemanticQueryPlanner


def _schema():
    return SemanticSchemaEngine().infer(pd.DataFrame({
        "Customer Key": [101, 102, 103, 104],
        "Brand": ["A", "B", "A", "C"],
        "Vendor": ["V1", "V2", "V1", "V3"],
        "Country": ["India", "India", "Japan", "Japan"],
        "Region": ["North", "South", "East", "West"],
        "State": ["WB", "MH", "KA", "DL"],
        "City": ["Kolkata", "Mumbai", "Bengaluru", "Delhi"],
        "Status": ["Open", "Closed", "Open", "Pending"],
        "Is Active": [True, False, True, True],
        "Revenue Amount": [100.0, 200.0, 150.0, 250.0],
        "Conversion Rate": [0.10, 0.25, 0.30, 0.15],
        "Customer Rating": [4.5, 3.0, 5.0, 2.5],
        "Units Sold": [2, 4, 3, 5],
        "Order Count": [1, 2, 1, 3],
        "Duration Minutes": [15, 30, 45, 20],
        "Review Commentary": [
            "very useful product and fast delivery",
            "good quality and helpful support",
            "excellent experience overall",
            "poor packaging but usable",
        ],
        "Event Timestamp": pd.to_datetime([
            "2026-05-01 10:00", "2026-05-02 11:30", "2026-05-03 12:00", "2026-05-04 09:15"
        ]),
    }))


def test_generic_ontology_coverage():
    schema = _schema()
    expected = {
        "Customer Key": "identifier",
        "Brand": "entity",
        "Vendor": "entity",
        "Country": "country",
        "Region": "region",
        "State": "state",
        "City": "city",
        "Status": "status",
        "Is Active": "boolean",
        "Revenue Amount": "currency_measure",
        "Conversion Rate": "percentage",
        "Customer Rating": "rating",
        "Units Sold": "quantity",
        "Order Count": "count",
        "Duration Minutes": "numeric_measure",
        "Review Commentary": "free_text",
        "Event Timestamp": "datetime",
    }
    for name, role in expected.items():
        field = schema.field(name)
        assert field is not None, name
        assert field.semantic_role == role, (name, field.semantic_role, field.business_role)
        assert field.confidence > 0

    duration = schema.field("Duration Minutes")
    assert duration.business_role == "duration"
    assert duration.analytical_role == "measure"


def test_identifier_uses_uniqueness_and_key_signals():
    schema = _schema()
    key = schema.field("Customer Key")
    assert key is not None
    assert key.candidate_key
    assert key.uniqueness == 1.0
    assert key.relationship_potential


def test_free_text_is_not_collapsed_into_a_dimension():
    schema = _schema()
    field = schema.field("Review Commentary")
    assert field is not None
    assert field.semantic_role == "free_text"
    assert field.analytical_role is None


def test_boolean_detection_works_from_values_without_exact_column_name():
    df = pd.DataFrame({"Enabled Flag": ["yes", "NO", "true", "false"]})
    field = SemanticSchemaEngine().infer(df).field("Enabled Flag")
    assert field is not None
    assert field.semantic_role == "boolean"


def test_date_resolution_supports_alternate_transaction_and_delivery_names():
    df = pd.DataFrame({
        "Purchased On": pd.to_datetime(["2026-04-30", "2026-05-01"]),
        "Delivered On": pd.to_datetime(["2026-05-03", "2026-06-01"]),
        "Sales Value": [10, 20],
        "Brand Label": ["A", "B"],
    })
    schema = SemanticSchemaEngine().infer(df)
    planner = SemanticQueryPlanner()

    sales = planner.plan("sales in May", schema)
    delivered = planner.plan("products delivered in May", schema)

    assert sales.time_field == "Purchased On"
    assert delivered.time_field == "Delivered On"
    assert sales.time_filter == {"month": 5}
    assert sales.time_grain == "month"


def test_genuinely_ambiguous_dates_are_not_silently_selected():
    df = pd.DataFrame({
        "Created Date": pd.to_datetime(["2026-05-01", "2026-05-02"]),
        "Updated Date": pd.to_datetime(["2026-05-03", "2026-05-04"]),
        "Performance Value": [10, 20],
    })
    schema = SemanticSchemaEngine().infer(df)
    plan = SemanticQueryPlanner().plan("show May performance", schema)
    assert plan.time_field is None
    assert plan.ambiguities


def test_generic_query_plans_expose_required_semantic_structure():
    df = pd.DataFrame({
        "Order Date": pd.to_datetime(["2026-05-01", "2026-05-02"]),
        "Brand": ["A", "B"],
        "Vendor": ["V1", "V2"],
        "Region": ["North", "South"],
        "Revenue Amount": [100.0, 200.0],
        "Profit Amount": [10.0, -5.0],
        "Customer Count": [2, 3],
    })
    schema = SemanticSchemaEngine().infer(df)
    planner = SemanticQueryPlanner()

    plans = [
        planner.plan("top brands in May", schema),
        planner.plan("monthly revenue", schema),
        planner.plan("brands making losses", schema),
        planner.plan("revenue percentage by category", schema),
        planner.plan("top vendors by profit", schema),
        planner.plan("monthly sales by region", schema),
        planner.plan("customer count by state", schema),
    ]

    for plan in plans:
        payload = plan.to_dict()
        assert set((
            "intent", "dimensions", "metric", "aggregation", "time_field",
            "time_grain", "time_filter", "filters", "sort", "limit",
            "confidence", "assumptions", "ambiguities",
        )) <= payload.keys()
        assert 0 <= plan.confidence <= 1

    assert plans[0].intent == "ranking"
    assert plans[0].limit == 10
    assert plans[1].time_grain == "month"
    assert plans[2].filters
    assert plans[4].metric == "Profit Amount"
    assert "Region" in plans[5].dimensions


def test_semantic_safe_output_contains_metadata_not_cell_values():
    df = pd.DataFrame({
        "Customer Name": ["PRIVATE_A", "PRIVATE_B"],
        "Revenue Amount": [10, 20],
    })
    safe = SemanticSchemaEngine().infer(df).to_safe_dict()
    rendered = repr(safe)
    assert "PRIVATE_A" not in rendered
    assert "PRIVATE_B" not in rendered
    assert "values" not in rendered
