from pathlib import Path

import system_diagnostics


def test_diagnostics_shape_and_privacy(monkeypatch):
    monkeypatch.delenv("INSIGHTFLOW_DIAGNOSTICS_DEBUG", raising=False)
    result = system_diagnostics.build_diagnostics()
    assert result["success"] is True
    assert result["response_type"] == "system_diagnostics"
    assert set(result["privacy"]) == {
        "local_dataset_processing",
        "raw_dataset_external_transmission",
        "metadata_only_ai_mode",
    }
    assert "_internal" in result and result["_internal"] == {}
    serialized = repr(result)
    assert "C:\\Users" not in serialized
    assert "/home/" not in serialized
    assert "GOOGLE_API_KEY" not in serialized


def test_stale_frontend_detection(monkeypatch, tmp_path):
    frontend = tmp_path / "frontend" / "flutter_detail"
    frontend.mkdir(parents=True)
    (frontend / "index.html").write_text(
        '<meta name="detail-analysis-build-id" content="served123">', encoding="utf-8"
    )
    (frontend / "main.dart.js").write_text("bundle", encoding="utf-8")
    (frontend / "flutter_bootstrap.js").write_text("bootstrap", encoding="utf-8")
    monkeypatch.setattr(system_diagnostics, "_frontend_root", lambda: frontend)
    monkeypatch.setenv("INSIGHTFLOW_EXPECTED_FRONTEND_BUILD_ID", "expected456")
    status = system_diagnostics._frontend_status(None)
    assert status["status"] == "stale"
    assert status["stale_build"] is True


def test_missing_frontend_build(monkeypatch, tmp_path):
    frontend = tmp_path / "frontend" / "flutter_detail"
    frontend.mkdir(parents=True)
    monkeypatch.setattr(system_diagnostics, "_frontend_root", lambda: frontend)
    status = system_diagnostics._frontend_status(None)
    assert status["status"] == "unavailable"
    assert status["stale_build"] is False


def test_recovery_actions_are_structured():
    actions = system_diagnostics._recovery(
        {"status": "stale"},
        {"report_generation": "unavailable"},
        {"privacy": "healthy"},
    )
    assert actions
    assert {"id", "severity", "title", "action", "automatic"} <= set(actions[0])
