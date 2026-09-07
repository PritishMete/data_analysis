from __future__ import annotations

import asyncio
import json
import os

import pandas as pd
import pytest

from learning_bridge import LearningBridgeClient, LearningBridgeConfig, build_learning_event, build_safe_query_abstraction


def _integration_url() -> str | None:
    return (
        os.environ.get("INSIGHT_LEARNING_INTEGRATION_URL")
        or os.environ.get("LEARNING_SERVICE_URL")
        or os.environ.get("INSIGHT_LEARNING_URL")
    )


def test_live_student_bridge_round_trip():
    url = _integration_url()
    if not url:
        pytest.skip("Set INSIGHT_LEARNING_INTEGRATION_URL or LEARNING_SERVICE_URL to run the live bridge test.")

    df = pd.DataFrame(
        {
            "Customer Name": ["John Smith"],
            "Company": ["SecretCompanyXYZ"],
            "Account Number": ["ACC-9988"],
            "Email": ["john@example.com"],
            "Phone": ["9876543210"],
            "Revenue": [120],
        }
    )
    user_text = "show John Smith from SecretCompanyXYZ with john@example.com and ACC-9988 and 9876543210"
    abstraction = build_safe_query_abstraction(user_text, df, ["Sheet1"])

    client = LearningBridgeClient(
        LearningBridgeConfig(
            base_url=url.rstrip("/"),
            enabled=True,
            timeout_seconds=5.0,
            min_sql_confidence=0.0,
            token="",
            circuit_failure_threshold=3,
            circuit_cooldown_seconds=30.0,
        )
    )

    safe_literals = [
        "John Smith",
        "john@example.com",
        "ACC-9988",
        "SecretCompanyXYZ",
        "9876543210",
        "Sheet1",
    ]

    plan_payload = abstraction.to_plan_request()
    plan_raw = client._post_json("/v1/plan", plan_payload)
    assert plan_raw is not None
    assert "plan_source" in plan_raw
    assert "confidence" in plan_raw
    assert "critic_status" in plan_raw

    plan_serialized = json.dumps(plan_raw, sort_keys=True)
    for literal in safe_literals:
        assert literal not in plan_serialized

    plan_result = asyncio.run(client.plan(abstraction))
    if plan_raw.get("plan") is None:
        assert plan_result is None
    else:
        assert plan_result is not None
        assert plan_result.plan == plan_raw["plan"]

    result = {
        "success": True,
        "route": "sql",
        "confidence": 0.97,
        "plan_source": "validated_template",
        "plan_template_id": "template.safe.001",
        "skill_id": "learned.analytics.v1",
        "plan": {
            "tool_sequence": ["sql.query"],
            "filters": [],
            "group_by": ["FIELD_01"],
            "metrics": [{"column": "FIELD_06", "function": "sum", "alias": "total_revenue"}],
        },
        "result": {
            "columns": ["Customer Name", "total_revenue"],
            "rows": [{"Customer Name": "John Smith", "total_revenue": 120}],
            "row_count": 1,
        },
        "critic_passed": True,
        "result_validation_passed": True,
        "plan_completeness_passed": True,
        "privacy_validation_passed": True,
        "no_unresolved_ambiguity": True,
        "no_critical_repair": True,
        "repair_count": 0,
        "correction_state": "validated",
        "quality_score": 0.97,
    }
    event = build_learning_event(user_text=user_text, abstraction=abstraction, result=result)
    event_payload = event.to_dict()
    event_serialized = json.dumps(event_payload, sort_keys=True)
    for literal in safe_literals:
        assert literal not in event_serialized

    ingest_raw = asyncio.run(client.ingest(event))
    assert ingest_raw is not None
    assert ingest_raw.get("stored") is True
    ingest_serialized = json.dumps(ingest_raw, sort_keys=True)
    for literal in safe_literals:
        assert literal not in ingest_serialized
