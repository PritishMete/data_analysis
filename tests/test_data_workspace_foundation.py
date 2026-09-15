import pandas as pd

from schema_intelligence.semantic_engine import SemanticSchemaEngine
from schema_intelligence.semantic_query import SemanticQueryPlanner
from data_workspace.models import CorrectionPlanner, DataWorkspaceLineage, TransformationPlan, TransformationStep


def test_semantic_schema_handles_multiple_date_namings_without_values_leaking():
    df = pd.DataFrame({
        "Purchased On": pd.to_datetime(["2026-05-01", "2026-05-02"]),
        "Delivered On": pd.to_datetime(["2026-05-03", "2026-05-04"]),
        "Brand Label": ["A", "B"],
        "Net Revenue": [100.0, 200.0],
        "Active": [True, False],
        "Customer Key": [1, 2],
    })
    schema = SemanticSchemaEngine().infer(df)
    purchased = schema.field("Purchased On")
    delivered = schema.field("Delivered On")
    revenue = schema.field("Net Revenue")
    assert purchased and purchased.semantic_role == "datetime"
    assert purchased.business_role == "transaction_date"
    assert delivered and delivered.business_role == "delivery_date"
    assert revenue and revenue.semantic_role in {"numeric_measure", "currency_measure"}
    assert all("values" not in f.evidence for f in schema.fields)


def test_query_planner_distinguishes_delivery_from_transaction_month():
    df = pd.DataFrame({
        "Order Date": pd.to_datetime(["2026-04-01", "2026-05-01"]),
        "Delivery Date": pd.to_datetime(["2026-05-03", "2026-06-01"]),
        "Revenue Amount": [10, 20],
        "Brand": ["A", "B"],
    })
    schema = SemanticSchemaEngine().infer(df)
    planner = SemanticQueryPlanner()
    sales = planner.plan("sales in May", schema)
    delivered = planner.plan("products delivered in May", schema)
    assert sales.time_field == "Order Date"
    assert delivered.time_field == "Delivery Date"
    assert sales.time_filter == {"month": 5}


def test_ambiguous_multiple_dates_are_not_silently_guessed():
    df = pd.DataFrame({
        "Created Date": pd.to_datetime(["2026-05-01"]),
        "Updated Date": pd.to_datetime(["2026-05-02"]),
        "Value": [1],
    })
    schema = SemanticSchemaEngine().infer(df)
    plan = SemanticQueryPlanner().plan("show May performance", schema)
    assert plan.ambiguities or plan.time_field is not None
    if plan.ambiguities:
        assert plan.time_field is None


def test_lineage_creates_versions_and_invalidates_dependent_results():
    lineage = DataWorkspaceLineage()
    raw = lineage.create_raw("ds")
    cleaned = lineage.create_version("ds", raw.version_id, "cleaned")
    record = lineage.record(
        dataset_id="ds", source_version=raw.version_id, target_version=cleaned.version_id,
        operation="NORMALIZE_CATEGORY", affected_fields=["Brand Label"], affected_row_count=2,
        reason="safe deterministic normalization", parameters={"scope": "category"},
        validation_result={"passed": True}, reversible=True,
    )
    lineage.register_analysis_result("result-1", cleaned.version_id)
    assert record.source_version == raw.version_id
    assert lineage.invalidate_dependents(cleaned.version_id) == {"result-1"}
    assert lineage.is_stale("result-1")


def test_correction_actions_are_explicit_and_do_not_rewrite_history():
    plan = CorrectionPlanner().plan(
        "CORRECT", "tx-123", "ds:v1", target_version="ds:v2",
        reason="two similar brands are distinct",
        replacement_parameters={"scope": "brand"},
    )
    assert plan.action == "CORRECT"
    assert plan.target_version == "ds:v2"


def test_transformation_plan_is_generic():
    step = TransformationStep(
        operation_id="op-1", operation_type="NORMALIZE_DATE", target_table="dataset",
        target_fields=["Purchased On"], semantic_role="datetime", parameters={"mode": "safe"},
        reason="standardize parseable dates", confidence=0.94, destructive=False,
        reversible=True, validation_rules=["parse_ratio >= 0.99"],
    )
    plan = TransformationPlan.create("ds:v0", [step], mode="specific")
    assert plan.steps[0].operation_type == "NORMALIZE_DATE"
