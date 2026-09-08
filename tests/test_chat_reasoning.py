import pytest
from fastapi.testclient import TestClient
import pandas as pd

from common.chat_reasoning import (
    ChatAnalysisPlan,
    compose_analyst_answer,
    deterministic_chat_plan,
    render_local_template,
    validate_chat_plan,
    build_follow_up_context,
    resolve_follow_up,
    FINDING_ACTION_REGISTRY,
    build_answer_blueprint,
)
from main import app


@pytest.mark.parametrize("query", [
    "is customer information reliable?",
    "anything suspicious about customers?",
    "review customer integrity",
    "what needs attention in customers?",
    "does customer data look healthy?",
    "inspect customer quality",
])
def test_customer_quality_variants_use_semantic_plan(query):
    plan = deterministic_chat_plan(query, {"customer_dimension_candidate", "transaction_fact_candidate"})
    assert plan.intent == "data_quality_analysis"
    assert plan.dataset_scope == ("customer_dimension_candidate",)
    assert "cross_table_consistency" in plan.operations
    assert plan.mutation_requested is False


def test_response_depth_is_semantic_not_dataset_specific():
    assert deterministic_chat_plan("quickly tell me customer issues").response_depth == "concise"
    assert deterministic_chat_plan("give me detailed customer quality analysis").response_depth == "detailed"
    assert deterministic_chat_plan("what are the issues with customers").response_depth == "standard"


def test_validator_rejects_unsafe_or_unknown_plan_fields():
    with pytest.raises(ValueError):
        validate_chat_plan({"intent": "cleaning", "dataset_scope": [], "operations": ["python"], "code": "x"})
    with pytest.raises(ValueError):
        validate_chat_plan({"intent": "data_quality_analysis", "dataset_scope": ["private_table"], "operations": []})
    with pytest.raises(ValueError):
        validate_chat_plan({"intent": "cleaning", "dataset_scope": [], "operations": [], "mutation_requested": True})


def test_template_binding_is_allowlisted_and_local():
    assert render_local_template("{duplicate_rows} rows in {duplicate_groups} groups", {"duplicate_rows": 4, "duplicate_groups": 2}) == "4 rows in 2 groups"
    with pytest.raises(ValueError):
        render_local_template("{raw_customer_id}", {"raw_customer_id": "secret"})


def test_composer_uses_local_fixture_evidence_and_groups_findings():
    result = {
        "datasets": [{
            "name": "customer_source",
            "profile": {"quality_summary": {"exact_duplicate_rows": 3}, "invalid_or_suspicious_values": [], "categorical_inconsistencies": []},
        }],
        "relationships": [{"source_table": "orders", "source_column": "customer_key", "target_table": "customer_source", "null_fk_count": 2, "orphan_rows": 5, "non_null_referential_coverage": .8}],
    }
    answer = compose_analyst_answer(result, "customer")
    assert "CONFIRMED ISSUES" in answer["answer"]
    assert len([item for item in answer["analytical_issues"] if item["issue_family"] == "duplicate_entity"]) == 1
    assert "excess row(s)" in answer["answer"]
    assert any(item["issue_family"] == "duplicate_entity" for item in answer["analytical_issues"])
    assert "missing Customer references" in answer["answer"]
    changed = compose_analyst_answer({**result, "datasets": [{"name": "customer_source", "profile": {"quality_summary": {"exact_duplicate_rows": 9}}}]}, "customer")
    assert "excess row(s)" in changed["answer"]
    assert "short_answer" in changed
    assert "customer_source" not in changed["short_answer"]


def test_planner_endpoint_accepts_only_abstract_context():
    response = TestClient(app).post("/v1/chat/plan", json={
        "query": "anything suspicious about customers?",
        "dataset_roles": ["customer_dimension_candidate", "transaction_fact_candidate"],
        "capabilities": ["quality_validation", "cross_table_consistency"],
        "conversation_context": {"last_intent": "data_quality_analysis"},
    })
    assert response.status_code == 200
    body = response.json()
    assert body["plan"]["intent"] == "data_quality_analysis"
    assert body["planner"] == "deterministic_fallback"
    assert body["privacy"]["raw_data_sent"] is False

    rejected = TestClient(app).post("/v1/chat/plan", json={
        "query": "review customers_raw.csv customer_id 123",
        "dataset_roles": ["customer_dimension_candidate"],
        "capabilities": [],
        "rows": [{"customer_id": 123}],
    })
    assert rejected.status_code == 400


def test_enabled_gemini_path_is_captured_and_metadata_only(monkeypatch):
    import ai_analyst

    captured = []

    async def fake_agent(_agent, _app_name, prompt):
        captured.append(prompt)
        return '{"intent":"data_quality_analysis","dataset_scope":["customer_dimension_candidate"],"operations":["quality_validation"],"comparison_scope":[],"response_mode":"analyst_explanation","mutation_requested":false,"confidence":0.95}'

    monkeypatch.setenv("DETAIL_ANALYSIS_CHAT_GEMINI_ENABLED", "true")
    monkeypatch.setenv("DETAIL_ANALYSIS_ALLOW_METADATA_AI", "true")
    monkeypatch.setattr(ai_analyst, "LlmAgent", lambda **kwargs: object())
    monkeypatch.setattr(ai_analyst, "_run_single_agent", fake_agent)
    response = TestClient(app).post("/v1/chat/plan", json={
        "query": "what are the issues with customer raw data",
        "dataset_roles": ["customer_dimension_candidate", "transaction_fact_candidate"],
        "capabilities": ["quality_validation"],
        "conversation_context": {},
    })
    assert response.status_code == 200
    assert response.json()["planner"] == "gemini"
    assert "customer raw data" in captured[0]
    assert "customer_id" not in captured[0]
    assert "customers_raw.csv" not in captured[0]
    assert "rows" not in captured[0]


def test_follow_ups_resolve_local_finding_ids_and_actions():
    plan = ChatAnalysisPlan("data_quality_analysis", ("customer_dimension_candidate",), tuple(), tuple(), confidence=.9)
    answer = compose_analyst_answer({
        "datasets": [{"name": "customers", "profile": {"quality_summary": {"exact_duplicate_rows": 2}}}],
        "relationships": [],
    }, "customer")
    findings = [type("Finding", (), item) for item in answer["findings"]]
    context = build_follow_up_context(plan, findings)
    why = resolve_follow_up("why is the first issue important?", context)
    fix = resolve_follow_up("can you fix it?", context)
    assert why["kind"] == "why"
    assert why["finding_id"] == findings[0].id
    assert fix["kind"] == "fix"
    assert fix["action"] == FINDING_ACTION_REGISTRY["duplicate_records"]


def test_follow_up_defaults_unknown_mutation_to_review_only():
    context = {"last_findings": [{"id": "x", "category": "unknown", "severity": "needs_review"}], "last_selected_finding_id": "x"}
    result = resolve_follow_up("fix it", context)
    assert result["action"]["allowed_action"] == "review_only"
    assert result["action"]["workflow"] is None


def test_local_evidence_captures_temporal_rows_and_scope():
    from common.chat_reasoning import build_quality_evidence, build_structured_findings

    tables = {
        "customers": pd.DataFrame({"customer_id": ["C1"], "signup_date": ["2025-05-10"]}),
        "orders": pd.DataFrame({"order_id": ["O1"], "customer_id": ["C1"], "order_date": ["2025-03-02"]}),
        "regions": pd.DataFrame({"region_id": ["R1"]}),
    }
    evidence = build_quality_evidence(tables)
    temporal = next(item for item in evidence["customers"] if item["finding_type"] == "cross_table_temporal_inconsistency")
    assert temporal["affected_row_count"] == 1
    assert len(temporal["example_rows"]) == 1
    result = {"datasets": [{"name": "customers", "profile": {"quality_evidence": evidence["customers"], "quality_summary": {}}}], "relationships": []}
    findings = build_structured_findings(result, "customer")
    assert {item.category for item in findings} == {"cross_table_temporal_inconsistency"}
    assert all(item.category != "duplicate_business_key" for item in findings)


def test_no_issue_fixture_does_not_invent_findings():
    answer = compose_analyst_answer({"datasets": [{"name": "customers", "profile": {"quality_summary": {}, "schema": [], "quality_evidence": [], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}], "relationships": []}, "customer")
    assert len(answer["findings"]) == 1
    assert answer["findings"][0]["passed"] is True
    assert "PASSED CHECKS" in answer["answer"]


def test_quality_evidence_adds_semantic_validation_and_synthetic_observation():
    from common.chat_reasoning import build_quality_evidence

    evidence = build_quality_evidence({"customers": pd.DataFrame({
        "customer_id": ["C1", "C2"],
        "customer_name": ["Customer 1", "Customer 2"],
        "email": ["valid@example.com", "not-an-email"],
    })})["customers"]
    assert any(item["finding_type"] == "invalid_semantic_field" and item["field_role"] == "email" for item in evidence)
    assert any(item["finding_type"] == "synthetic_pattern" for item in evidence)


def test_temporal_evidence_reports_affected_entities_and_percentage():
    from common.chat_reasoning import build_quality_evidence

    evidence = build_quality_evidence({
        "customers": pd.DataFrame({"customer_id": ["C1", "C2"], "signup_date": ["2025-05-10", "2025-01-01"]}),
        "orders": pd.DataFrame({"order_id": ["O1", "O2"], "customer_id": ["C1", "C2"], "order_date": ["2025-03-02", "2025-02-01"]}),
    })["customers"]
    temporal = next(item for item in evidence if item["finding_type"] == "cross_table_temporal_inconsistency")
    assert temporal["affected_row_count"] == 1
    assert temporal["affected_entity_count"] == 1
    assert temporal["affected_percentage"] == 50.0


def test_answer_model_and_blueprint_are_structured_and_allowlisted():
    answer = compose_analyst_answer({"datasets": [{"name": "customers", "profile": {"quality_summary": {}, "schema": [], "quality_evidence": [], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}], "relationships": []}, "customer")
    assert set(("headline", "confirmed_issues", "minor_observations", "passed_checks", "recommendation")) <= set(answer["analyst_response_model"])
    assert answer["answer_blueprint"]["sections"][0] == "confirmed_issues"
    assert "raw" not in str(answer["answer_blueprint"]).casefold()


def test_duplicate_key_and_exact_rows_consolidate_into_one_analytical_issue():
    from common.chat_reasoning import build_quality_evidence, compose_analyst_answer
    frame = pd.DataFrame({"customer_id": ["C1", "C1", "C2"], "name": ["A", "A", "B"]})
    evidence = build_quality_evidence({"customers": frame})["customers"]
    answer = compose_analyst_answer({"datasets": [{"name": "customers", "profile": {"quality_summary": {"exact_duplicate_rows": 1}, "quality_evidence": evidence, "schema": [], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}], "relationships": []}, "customer")
    duplicates = [item for item in answer["analytical_issues"] if item["issue_family"] == "duplicate_entity"]
    assert len(duplicates) == 1
    assert "exact_duplicate_excess_rows" in duplicates[0]["evidence"]
    assert "duplicate_identifier_groups" in duplicates[0]["evidence"] or "exact_duplicate_excess_rows" in duplicates[0]["evidence"]


def test_relationship_findings_distinguish_null_and_orphan_references():
    from common.chat_reasoning import consolidate_findings
    base = {"datasets": [{"name": "customers", "profile": {"quality_summary": {}, "schema": [], "quality_evidence": [], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}]}
    null_issues = consolidate_findings({**base, "relationships": [{"source_table": "orders", "source_column": "customer_id", "target_table": "customers", "source_nulls": 10, "orphan_rows": 0, "non_null_referential_coverage": 1.0}]}, "customer")
    assert "missing Customer references" in null_issues[0].title
    orphan_issues = consolidate_findings({**base, "relationships": [{"source_table": "orders", "source_column": "customer_id", "target_table": "customers", "source_nulls": 0, "orphan_rows": 10, "non_null_referential_coverage": .9}]}, "customer")
    assert "unknown Customer references" in orphan_issues[0].title


def test_prioritizer_places_high_impact_temporal_issue_before_small_duplicate():
    from common.chat_reasoning import compose_analyst_answer
    result = {"datasets": [{"name": "customers", "profile": {"quality_summary": {"exact_duplicate_rows": 1}, "schema": [], "quality_evidence": [{"finding_type": "cross_table_temporal_inconsistency", "related_dataset": "orders", "affected_row_count": 900, "affected_entity_count": 90, "total_entity_count": 100, "affected_percentage": 90.0, "example_rows": []}], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}], "relationships": []}
    issues = compose_analyst_answer(result, "customer")["analytical_issues"]
    assert issues[0]["issue_family"] == "temporal_integrity"


def test_structured_response_contract_preserves_examples_and_scope():
    from common.chat_reasoning import compose_analyst_answer
    result = {"datasets": [{"name": "customers", "profile": {"quality_summary": {"exact_duplicate_rows": 1}, "schema": [], "quality_evidence": [{"finding_type": "duplicate_business_key", "column": "customer_id", "affected_row_count": 2, "duplicate_group_count": 1, "example_rows": [{"source_row": 2, "value": "C1"}]}], "invalid_or_suspicious_values": [], "categorical_inconsistencies": []}}], "relationships": []}
    answer = compose_analyst_answer(result, "customer")
    structured = answer["structured_responses"]["customer"]
    assert structured["response_type"] == "analyst_quality_response"
    assert structured["confirmed_issues"][0]["examples"]["rows"]
    assert structured["copy_text"]
