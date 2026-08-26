from __future__ import annotations

import asyncio
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pandas as pd

import query_router
from learning_bridge import LearningBridgeClient, LearningBridgeConfig, build_learning_event, build_safe_query_abstraction


STUDENT_REPO = Path(os.environ.get("INSIGHT_LEARNING_REPO", r"E:\LLM"))
STUDENT_PYTHON = Path(
    os.environ.get(
        "INSIGHT_LEARNING_PYTHON",
        r"C:\Users\jiban\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe",
    )
)
SENSITIVE_VALUES = [
    "John Smith",
    "john@example.com",
    "ACC-9988",
    "SecretCompanyXYZ",
    "9876543210",
]


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _python_executable() -> Path:
    if STUDENT_PYTHON.exists():
        return STUDENT_PYTHON
    fallback = Path(sys.executable)
    return fallback


def _json_request(method: str, url: str, payload: dict | None = None) -> dict:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    with urllib.request.urlopen(request, timeout=20) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def _wait_for_health(base_url: str, proc: subprocess.Popen[str], timeout_seconds: float = 45.0) -> None:
    deadline = time.time() + timeout_seconds
    last_error: str | None = None
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"Student service exited early with code {proc.returncode}.")
        try:
            payload = _json_request("GET", f"{base_url}/v1/health")
            if payload.get("status") == "ok":
                return
        except Exception as exc:  # pragma: no cover - exercised in live integration only
            last_error = str(exc)
        time.sleep(0.5)
    raise RuntimeError(f"Student service did not become healthy: {last_error or 'no response'}")


def _start_student_service(tmp_path: Path) -> tuple[subprocess.Popen[str], str, Path, Path]:
    port = _free_port()
    runtime_dir = tmp_path / "student_runtime"
    state_dir = tmp_path / "student_state"
    db_path = runtime_dir / "learning.db"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    pythonpath = str(STUDENT_REPO)
    if env.get("PYTHONPATH"):
        pythonpath = pythonpath + os.pathsep + env["PYTHONPATH"]
    env.update(
        {
            "PYTHONUNBUFFERED": "1",
            "INSIGHT_LEARNING_RUNTIME_DIR": str(runtime_dir),
            "DATA_ANALYSIS_LLM_STATE_DIR": str(state_dir),
            "INSIGHT_LEARNING_DB_PATH": str(db_path),
            "PYTHONPATH": pythonpath,
        }
    )

    cmd = [
        str(_python_executable()),
        "-m",
        "uvicorn",
        "src.insight_learning.api.app:app",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--log-level",
        "warning",
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=str(STUDENT_REPO),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    base_url = f"http://127.0.0.1:{port}"
    _wait_for_health(base_url, proc)
    return proc, base_url, runtime_dir, state_dir


def _stop_student_service(proc: subprocess.Popen[str]) -> str:
    if proc.poll() is None:
        proc.terminate()
        try:
            stdout, _ = proc.communicate(timeout=15)
            return stdout or ""
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, _ = proc.communicate(timeout=15)
            return stdout or ""
    stdout, _ = proc.communicate(timeout=5)
    return stdout or ""


def _example_frame(seed: int) -> pd.DataFrame:
    return pd.DataFrame({"Price": [80 + seed, 120 + seed, 150 + seed, 220 + seed]})


def _privacy_frame(seed: int) -> pd.DataFrame:
    return pd.DataFrame(
        {
            "Customer Name": [
                "John Smith",
                "John Smith",
                "Jane Doe",
                "Alice Example",
            ],
            "Company": [
                "SecretCompanyXYZ",
                "SecretCompanyXYZ",
                "AnotherCo",
                "AnotherCo",
            ],
            "Account Number": [
                "ACC-9988",
                "ACC-9988",
                "ACC-9989",
                "ACC-9990",
            ],
            "Email": [
                "john@example.com",
                "john@example.com",
                "jane@example.com",
                "alice@example.com",
            ],
            "Phone": [
                "9876543210",
                "9876543210",
                "9123456789",
                "9012345678",
            ],
            "Region": ["North", "North", "South", "West"],
            "Revenue": [120 + seed, 180 + seed, 95 + seed, 210 + seed],
        }
    )


def _comparison_query_payload() -> dict[str, object]:
    return {
        "route": "sql",
        "confidence": 0.97,
        "message": "Filtered rows with price above a threshold.",
        "plan_source": "gemini",
        "plan_template_id": "template.filter.price.v1",
        "skill_id": "analysis.filter.price.v1",
        "plan": {
            "filters": [{"column": "Price", "operator": "greater_than", "value": 100}],
            "group_by": [],
            "metrics": [],
            "order_by": [],
            "tool_sequence": ["sql.filter"],
        },
        "result": {
            "columns": ["Price"],
            "rows": [{"Price": 120}, {"Price": 150}, {"Price": 220}],
            "row_count": 3,
        },
        "critic_passed": True,
        "result_validation_passed": True,
        "plan_completeness_passed": True,
        "privacy_validation_passed": True,
        "no_unresolved_ambiguity": True,
        "no_critical_repair": True,
        "repair_count": 0,
        "correction_state": "validated",
    }


def _build_learning_event(
    user_text: str,
    df: pd.DataFrame,
    result: dict[str, object],
    *,
    event_id: str,
    quality: float = 0.97,
    plan_source: str | None = None,
    skill_id: str | None = None,
    plan_template_id: str | None = None,
):
    abstraction = build_safe_query_abstraction(user_text, df, ["Sheet1"])
    event = build_learning_event(user_text=user_text, result=result, abstraction=abstraction)
    event.event_id = event_id
    event.quality_score = quality
    event.critic_passed = bool(result.get("critic_passed")) if result.get("critic_passed") is not None else True
    event.result_validation_passed = bool(result.get("result_validation_passed")) if result.get("result_validation_passed") is not None else True
    event.plan_completeness_passed = bool(result.get("plan_completeness_passed")) if result.get("plan_completeness_passed") is not None else True
    event.privacy_validation_passed = bool(result.get("privacy_validation_passed")) if result.get("privacy_validation_passed") is not None else True
    event.no_unresolved_ambiguity = bool(result.get("no_unresolved_ambiguity")) if result.get("no_unresolved_ambiguity") is not None else True
    event.no_critical_repair = bool(result.get("no_critical_repair")) if result.get("no_critical_repair") is not None else True
    event.repair_count = int(result.get("repair_count") or 0)
    event.correction_state = str(result.get("correction_state") or "validated")
    event.plan_source = str(plan_source or result.get("plan_source") or "gemini")
    event.skill_id = str(skill_id or result.get("skill_id") or "analysis.filter.price.v1")
    event.plan_template_id = str(plan_template_id or result.get("plan_template_id") or "template.filter.price.v1")
    return event


def _experience_payload(
    *,
    user_text: str,
    df: pd.DataFrame,
    result: dict[str, object],
    event_id: str,
    quality: float,
    plan_source: str,
    skill_id: str,
    plan_template_id: str,
    execution_success: bool = True,
    validation_success: bool = True,
    critic_passed: bool = True,
    result_validation_passed: bool = True,
    plan_completeness_passed: bool = True,
    privacy_validation_passed: bool = True,
    no_unresolved_ambiguity: bool = True,
    no_critical_repair: bool = True,
    repair_count: int = 0,
    correction_state: str = "validated",
) -> dict[str, object]:
    abstraction = build_safe_query_abstraction(user_text, df, ["Sheet1"])
    plan = dict(result.get("plan") or {})
    result_payload = dict(result.get("result") or {})
    tool_graph = list(plan.get("tool_sequence") or [])
    return {
        "schema_version": 1,
        "event_id": event_id,
        "intent": abstraction.intent,
        "query_features": abstraction.query_features,
        "dataset_profile": {"fields": [field.to_dict() for field in abstraction.fields]},
        "tool_graph": tool_graph,
        "plan": plan,
        "execution": {
            "success": execution_success,
            "route": "sql",
            "result_kind": "table",
            "row_count": int(result_payload.get("row_count") or len(result_payload.get("rows") or [])),
            "column_count": int(len(result_payload.get("columns") or [])),
            "sql_present": bool(result.get("sql")),
        },
        "validation": {
            "success": validation_success,
            "warnings": [],
            "errors": [],
        },
        "quality_score": quality,
        "route": "sql",
        "plan_source": plan_source,
        "skill_id": skill_id,
        "plan_template_id": plan_template_id,
        "dataset_semantic_signature": abstraction.dataset_semantic_signature,
        "critic_passed": critic_passed,
        "result_validation_passed": result_validation_passed,
        "plan_completeness_passed": plan_completeness_passed,
        "privacy_validation_passed": privacy_validation_passed,
        "no_unresolved_ambiguity": no_unresolved_ambiguity,
        "no_critical_repair": no_critical_repair,
        "repair_count": repair_count,
        "correction_state": correction_state,
        "safe_query_abstraction": {
            "available_columns": [field.id for field in abstraction.fields],
            "available_sheet_count": len(abstraction.available_sheets),
            "dataset_semantic_signature": abstraction.dataset_semantic_signature,
        },
    }


def _assert_no_literals(payload: object) -> None:
    serialized = json.dumps(payload, sort_keys=True, default=str)
    for literal in SENSITIVE_VALUES:
        assert literal not in serialized


def test_live_student_learning_lifecycle_and_privacy(tmp_path, monkeypatch):
    proc, base_url, runtime_dir, state_dir = _start_student_service(tmp_path)
    bridge = LearningBridgeClient(
        LearningBridgeConfig(
            base_url=base_url,
            enabled=True,
            timeout_seconds=10.0,
            min_sql_confidence=0.0,
            token="",
            circuit_failure_threshold=3,
            circuit_cooldown_seconds=1.0,
        )
    )
    training_bridge = LearningBridgeClient(
        LearningBridgeConfig(
            base_url=base_url,
            enabled=True,
            timeout_seconds=10.0,
            min_sql_confidence=0.0,
            token="",
            circuit_failure_threshold=3,
            circuit_cooldown_seconds=1.0,
        )
    )
    gemini_calls = {"count": 0}
    bridge.enabled = False

    async def fake_router_agent(user_text: str, available_columns: list, df: pd.DataFrame | None = None) -> dict[str, object]:
        gemini_calls["count"] += 1
        payload = _comparison_query_payload()
        payload["message"] = f"Gemini fallback for: {user_text}"
        return payload

    monkeypatch.setattr(query_router, "get_learning_bridge", lambda: bridge)
    monkeypatch.setattr(query_router, "_run_router_agent", fake_router_agent)

    fallback_text = "analyze price above 100"
    user_text = "rows where price above 100"
    initial_result = asyncio.run(query_router.handle_smart_query(fallback_text, _example_frame(1), ["Sheet1"]))
    assert initial_result["route"] == "sql"
    assert gemini_calls["count"] == 1
    assert initial_result.get("plan_source") is None
    _assert_no_literals(initial_result)

    for index in range(1, 8):
        df = _example_frame(index)
        result = asyncio.run(query_router.handle_smart_query(user_text, df, ["Sheet1"]))
        assert result["route"] == "sql"
        assert result["plan"] is not None
        _assert_no_literals(result)

        payload = _experience_payload(
            user_text=user_text,
            df=df,
            result=result,
            event_id=f"evt_positive_{index:02d}",
            quality=0.97,
            plan_source="validated_template",
            skill_id="analysis.filter.price.v1",
            plan_template_id="template.filter.price.v1",
        )
        ingest_response = training_bridge._post_json("/v1/experience", payload)
        assert ingest_response is not None
        assert ingest_response["stored"] is True
        _assert_no_literals(ingest_response)

    privacy_frame = _privacy_frame(99)
    privacy_payload = _experience_payload(
        user_text=user_text,
        df=privacy_frame,
        result=initial_result,
        event_id="evt_privacy_check",
        quality=0.97,
        plan_source="validated_template",
        skill_id="analysis.filter.price.v1",
        plan_template_id="template.filter.price.v1",
    )
    privacy_response = training_bridge._post_json("/v1/experience", privacy_payload)
    assert privacy_response is not None
    assert privacy_response["stored"] is True
    _assert_no_literals(privacy_payload)
    _assert_no_literals(privacy_response)

    gemini_before_learn = gemini_calls["count"]
    bridge.enabled = True

    learned_result = asyncio.run(query_router.handle_smart_query(user_text, _example_frame(8), ["Sheet1"]))
    assert learned_result["route"] == "sql"
    assert learned_result["plan"] is not None
    assert learned_result.get("plan_source") != "gemini"
    assert gemini_calls["count"] == gemini_before_learn
    _assert_no_literals(learned_result)

    learned_plan = asyncio.run(bridge.plan(build_safe_query_abstraction(user_text, _example_frame(9), ["Sheet1"])))
    assert learned_plan is not None
    assert learned_plan.accepted is True
    assert learned_plan.plan_source != "gemini"
    _assert_no_literals(learned_plan.raw_response)

    skills_payload = _json_request("GET", f"{base_url}/v1/skills")
    learned_skills = [skill for skill in skills_payload["skills"] if str(skill.get("id") or "").startswith("learned.")]
    assert learned_skills
    assert any(skill.get("lifecycle") in {"validated", "trusted"} for skill in learned_skills)
    assert any(skill.get("lifecycle") == "trusted" for skill in learned_skills)
    _assert_no_literals(skills_payload)

    metrics_payload = _json_request("GET", f"{base_url}/v1/metrics")
    metrics = metrics_payload["metrics"]
    assert metrics["experiences"] >= 7
    assert metrics["candidate_strategies"] >= 1
    assert metrics["skills"] >= 1
    _assert_no_literals(metrics_payload)

    bad_result = _comparison_query_payload()
    bad_result["result_validation_passed"] = False
    bad_result["quality_score"] = 0.97
    bad_payload = _experience_payload(
        user_text=user_text,
        df=_example_frame(10),
        result=bad_result,
        event_id="evt_bad_result",
        quality=0.97,
        plan_source="validated_template",
        skill_id="analysis.filter.price.v1",
        plan_template_id="template.filter.price.v1",
        result_validation_passed=False,
    )
    training_bridge._post_json("/v1/experience", bad_payload)

    bad_critic = _comparison_query_payload()
    bad_critic["critic_passed"] = False
    bad_critic["quality_score"] = 0.97
    bad_critic_payload = _experience_payload(
        user_text=user_text,
        df=_example_frame(11),
        result=bad_critic,
        event_id="evt_bad_critic",
        quality=0.97,
        plan_source="validated_template",
        skill_id="analysis.filter.price.v1",
        plan_template_id="template.filter.price.v1",
        critic_passed=False,
    )
    training_bridge._post_json("/v1/experience", bad_critic_payload)

    low_quality = _comparison_query_payload()
    low_quality["plan"]["filters"][0]["operator"] = "less_than"
    low_quality["plan"]["filters"][0]["value"] = 50
    low_quality["plan"]["filters"].append({"column": "Price", "operator": "greater_than_equal", "value": 10})
    low_quality["result"] = {
        "columns": ["Price"],
        "rows": [],
        "row_count": 0,
    }
    low_quality["quality_score"] = 0.80
    low_quality_payload = _experience_payload(
        user_text=user_text,
        df=_example_frame(12),
        result=low_quality,
        event_id="evt_low_quality",
        quality=0.80,
        plan_source="deterministic_fallback",
        skill_id="analysis.filter.price.v1",
        plan_template_id="template.filter.price.v1",
        critic_passed=True,
        result_validation_passed=True,
    )
    training_bridge._post_json("/v1/experience", low_quality_payload)

    export_preview = _json_request(
        "GET",
        f"{base_url}/v1/export/training-dataset?format=json&include_candidate_strategies=true&limit=10",
    )
    assert export_preview["exported"] is True
    assert export_preview["eligible_examples"] >= 1
    assert isinstance(export_preview["records"], list)
    assert any(record["output"]["candidate_state"] in {"validated", "trusted", "promoted"} for record in export_preview["records"] if record["source_kind"] == "strategy")
    _assert_no_literals(export_preview)

    export_report = _json_request(
        "GET",
        f"{base_url}/v1/export/training-dataset?format=report&include_candidate_strategies=false&persist=true&limit=1000",
    )
    report = export_report["report"]
    assert report["total_experiences_inspected"] >= 10
    assert report["eligible_examples"] == 1
    assert report["duplicates_removed"] >= 6
    assert report["rejected_examples"] >= 3
    assert report["rejection_reasons"].get("result_validation_failed", 0) >= 1
    assert report["rejection_reasons"].get("critic_failed", 0) >= 1
    assert report["rejection_reasons"].get("quality_below_threshold", 0) >= 1
    assert report["train_count"] + report["validation_count"] + report["test_count"] == report["eligible_examples"]
    assert report["average_quality"] >= 0.95
    _assert_no_literals(export_report)

    training_dir = runtime_dir / "training"
    assert (training_dir / "train.jsonl").exists()
    assert (training_dir / "validation.jsonl").exists()
    assert (training_dir / "test.jsonl").exists()
    assert (training_dir / "dataset_report.json").exists()

    for path in (training_dir / "train.jsonl", training_dir / "validation.jsonl", training_dir / "test.jsonl", training_dir / "dataset_report.json"):
        text = path.read_text(encoding="utf-8")
        for literal in SENSITIVE_VALUES:
            assert literal not in text

    persisted_report = json.loads((training_dir / "dataset_report.json").read_text(encoding="utf-8"))
    assert persisted_report["eligible_examples"] == 1
    assert persisted_report["train_count"] + persisted_report["validation_count"] + persisted_report["test_count"] == 1
    _assert_no_literals(persisted_report)

    restart_logs = _stop_student_service(proc)
    for literal in SENSITIVE_VALUES:
        assert literal not in restart_logs

    restarted_proc, restarted_base_url, _, _ = _start_student_service(tmp_path)
    try:
        restarted_bridge = LearningBridgeClient(
            LearningBridgeConfig(
                base_url=restarted_base_url,
                enabled=True,
                timeout_seconds=10.0,
                min_sql_confidence=0.0,
                token="",
                circuit_failure_threshold=3,
                circuit_cooldown_seconds=1.0,
            )
        )
        monkeypatch.setattr(query_router, "get_learning_bridge", lambda: restarted_bridge)
        restarted_result = asyncio.run(query_router.handle_smart_query(user_text, _example_frame(13), ["Sheet1"]))
        assert restarted_result["route"] == "sql"
        assert restarted_result["plan_source"] != "gemini"
        assert restarted_result["metadata"]["learning"]["used"] is True
        assert gemini_calls["count"] == gemini_before_learn
        assert asyncio.run(restarted_bridge.plan(build_safe_query_abstraction(user_text, _example_frame(14), ["Sheet1"]))) is not None
    finally:
        restart_logs = _stop_student_service(restarted_proc)
        for literal in SENSITIVE_VALUES:
            assert literal not in restart_logs
