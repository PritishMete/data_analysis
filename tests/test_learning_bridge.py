from __future__ import annotations

import asyncio
import json
from io import BytesIO
import urllib.error

import pandas as pd
from fastapi.testclient import TestClient

import main
import learning_bridge
import query_router
from learning_bridge import LearningBridgeClient, LearningPlanResult, build_learning_event, build_safe_query_abstraction


def test_learned_sql_plan_skips_gemini(monkeypatch):
    df = pd.DataFrame({"Region": ["North", "South"], "Revenue": [120, 80]})
    observed = {"gemini_called": False}

    class FakeBridge:
        async def plan(self, abstraction):
            return LearningPlanResult(
                accepted=True,
                confidence=0.95,
                plan_source="validated_template",
                route="sql",
                plan={
                    "group_by": ["FIELD_01"],
                    "metrics": [{"column": "FIELD_02", "function": "sum", "alias": "total_revenue"}],
                    "order_by": [{"column": "total_revenue", "direction": "desc"}],
                    "limit": 5,
                    "tool_sequence": ["sql.group_by"],
                },
                skill_id="learned.analytics.v1",
                plan_template_id="template.001",
                reverse_field_map={"FIELD_01": "Region", "FIELD_02": "Revenue"},
            )

    async def fail_router(*args, **kwargs):
        observed["gemini_called"] = True
        raise AssertionError("Gemini should not be used for a confident learned SQL plan.")

    monkeypatch.setattr(query_router, "get_learning_bridge", lambda: FakeBridge())
    monkeypatch.setattr(query_router, "_run_router_agent", fail_router)

    result = asyncio.run(query_router.handle_smart_query("total revenue by region", df, []))

    assert result["route"] == "sql"
    assert result["plan_source"] == "validated_template"
    assert result["plan_template_id"] == "template.001"
    assert result["result"]["row_count"] == 2
    assert observed["gemini_called"] is False


def test_learning_bridge_circuit_breaker_opens_after_repeated_failures(monkeypatch):
    df = pd.DataFrame({"Region": ["North"], "Revenue": [120]})
    abstraction = build_safe_query_abstraction("total revenue by region", df, [])
    client = LearningBridgeClient()
    client.enabled = True
    client.circuit_failure_threshold = 1
    client.circuit_cooldown_seconds = 60.0

    calls = {"count": 0}

    def fake_urlopen(*args, **kwargs):
        calls["count"] += 1
        raise urllib.error.URLError("student service unavailable")

    monkeypatch.setattr(learning_bridge.urllib.request, "urlopen", fake_urlopen)

    first = asyncio.run(client.plan(abstraction))
    second = asyncio.run(client.plan(abstraction))

    assert first is None
    assert second is None
    assert calls["count"] == 1
    assert client._circuit_open() is True


def test_learning_event_payload_is_safe_and_preserves_explicit_failures():
    df = pd.DataFrame(
        {
            "Customer Name": ["John Smith"],
            "Company": ["SecretCompanyXYZ"],
            "Account Number": ["ACC-9988"],
        }
    )
    abstraction = build_safe_query_abstraction(
        "show John Smith from SecretCompanyXYZ with john@example.com and ACC-9988 and 9876543210",
        df,
        ["Sheet1"],
    )
    event = build_learning_event(
        user_text="show John Smith from SecretCompanyXYZ with john@example.com and ACC-9988 and 9876543210",
        abstraction=abstraction,
        result={
            "success": True,
            "route": "sql",
            "confidence": 0.80,
            "plan_source": "gemini",
            "plan": {
                "group_by": ["FIELD_01"],
                "metrics": [{"column": "FIELD_02", "function": "sum", "alias": "total_value"}],
                "tool_sequence": ["sql.group_by"],
            },
            "critic_passed": False,
            "result_validation_passed": False,
            "plan_completeness_passed": False,
            "privacy_validation_passed": False,
            "repair_count": 0,
            "correction_state": "corrected",
        },
    )

    payload = json.dumps(event.to_dict(), sort_keys=True)
    for literal in [
        "John Smith",
        "john@example.com",
        "ACC-9988",
        "SecretCompanyXYZ",
        "9876543210",
        "Sheet1",
    ]:
        assert literal not in payload
    assert event.critic_passed is False
    assert event.result_validation_passed is False
    assert event.plan_completeness_passed is False
    assert event.privacy_validation_passed is False
    assert event.repair_count == 0
    assert event.correction_state == "corrected"
    assert event.safe_query_abstraction["available_columns"] == ["FIELD_01", "FIELD_02", "FIELD_03"]
    assert event.safe_query_abstraction["available_sheet_count"] == 1
    assert event.quality_score == 0.8


def test_learning_bridge_falls_back_to_gemini_when_student_bridge_fails(monkeypatch):
    df = pd.DataFrame({"Region": ["North", "South"], "Revenue": [120, 80]})
    observed = {"gemini_called": False}

    class FailingBridge:
        async def plan(self, abstraction):
            raise RuntimeError("bridge down")

    async def fake_router(*args, **kwargs):
        observed["gemini_called"] = True
        return {
            "route": "sql",
            "confidence": 0.91,
            "message": "Gemini fallback",
            "plan": {
                "group_by": ["Region"],
                "metrics": [{"column": "Revenue", "function": "sum", "alias": "total_revenue"}],
                "tool_sequence": ["sql.group_by"],
            },
        }

    monkeypatch.setattr(query_router, "get_learning_bridge", lambda: FailingBridge())
    monkeypatch.setattr(query_router, "_run_router_agent", fake_router)

    result = asyncio.run(query_router.handle_smart_query("total revenue by region", df, []))

    assert result["route"] == "sql"
    assert result["message"] == "Gemini fallback"
    assert observed["gemini_called"] is True


def test_smart_query_records_learning_event(monkeypatch):
    df = pd.DataFrame({"Region": ["North"], "Revenue": [120]})
    captured: dict[str, dict] = {}

    class FakeBridge:
        async def ingest(self, event):
            captured["event"] = event.to_dict()
            return {"stored": True}

    async def fake_handle_smart_query(text, dataframe, sheets):
        assert text == "total revenue by region"
        assert list(dataframe.columns) == ["Region", "Revenue"]
        return {
            "success": True,
            "route": "sql",
            "confidence": 0.94,
            "message": "ok",
            "plan_source": "validated_template",
            "plan_template_id": "template.002",
            "skill_id": "learned.analytics.v1",
            "plan": {
                "group_by": ["Region"],
                "metrics": [{"column": "Revenue", "function": "sum", "alias": "total_revenue"}],
                "tool_sequence": ["sql.group_by"],
            },
            "sql": "SELECT Region, SUM(Revenue) AS total_revenue FROM data GROUP BY Region",
            "result": {"columns": ["Region", "total_revenue"], "rows": [{"Region": "North", "total_revenue": 120}], "row_count": 1},
        }

    monkeypatch.setattr(main, "get_learning_bridge", lambda: FakeBridge())
    monkeypatch.setattr(main, "handle_smart_query", fake_handle_smart_query)
    monkeypatch.setattr(main, "_load_context_aware_dataframe", lambda *args, **kwargs: (df, None))

    queued: dict[str, object] = {}

    def fake_queue_learning_event(*, text, df, sheets, result):
        queued["coro"] = main._record_learning_event(text=text, df=df, sheets=sheets, result=result)

    monkeypatch.setattr(main, "_queue_learning_event", fake_queue_learning_event)

    client = TestClient(main.app)
    response = client.post(
        "/smart_query",
        files={"file": ("sample.csv", BytesIO(b"Region,Revenue\nNorth,120\n"), "text/csv")},
        data={"text": "total revenue by region", "available_sheets": "[]"},
    )

    assert response.status_code == 200
    assert "coro" in queued
    assert "event" not in captured
    asyncio.run(queued["coro"])
    assert captured["event"]["route"] == "sql"
    assert captured["event"]["plan_source"] == "validated_template"
    assert captured["event"]["safe_query_abstraction"]["available_columns"] == ["FIELD_01", "FIELD_02"]
    assert captured["event"]["dataset_semantic_signature"] is not None
