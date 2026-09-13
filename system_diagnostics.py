"""Privacy-safe local diagnostics for InsightFlow.

This module deliberately reports only service/build/configuration state. It never
reads or returns dataset values, filenames, absolute paths, secrets, or exception
tracebacks.
"""
from __future__ import annotations

import hashlib
import importlib
import logging
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from privacy_policy import LOCAL_ONLY

logger = logging.getLogger("insightflow.diagnostics")
STARTED_AT = datetime.now(timezone.utc)
_START_MONOTONIC = time.monotonic()

REQUIRED_IMPORTS = {
    "detail_analysis": ("common.detail_analysis", "analyze_dataset_collection"),
    "business_analysis": ("common.business_analysis", "analyze_clean_model"),
    "conversation_state": ("common.conversation_state", "ConversationStateStore"),
    "report_generation": ("ai_analyst", "generate_report"),
}


def _repo_root() -> Path:
    return Path(__file__).resolve().parent


def _frontend_root() -> Path:
    return _repo_root() / "frontend" / "flutter_detail"


def _frontend_build_files() -> tuple[Path, Path, Path]:
    root = _frontend_root()
    return root / "index.html", root / "main.dart.js", root / "flutter_bootstrap.js"


def _hash_build(bundle: Path) -> str | None:
    try:
        if not bundle.is_file():
            return None
        digest = hashlib.sha256()
        with bundle.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()[:12].lower()
    except OSError:
        return None


def _read_meta_build_id(index: Path) -> str | None:
    try:
        text = index.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = re.search(r'<meta[^>]+name=["\']detail-analysis-build-id["\'][^>]+content=["\']([a-zA-Z0-9_-]+)["\']', text, re.I)
    if not match:
        match = re.search(r'<meta[^>]+content=["\']([a-zA-Z0-9_-]+)["\'][^>]+name=["\']detail-analysis-build-id["\']', text, re.I)
    return match.group(1) if match else None


def _service_check(module_name: str, symbol: str) -> tuple[str, str | None]:
    try:
        module = importlib.import_module(module_name)
        getattr(module, symbol)
        return "healthy", None
    except Exception:
        return "unavailable", "required_local_module_unavailable"


def _frontend_status(client_build_id: str | None) -> dict[str, Any]:
    index, bundle, bootstrap = _frontend_build_files()
    files_ok = all(path.is_file() for path in (index, bundle, bootstrap))
    if not files_ok:
        return {
            "status": "unavailable",
            "detail_analysis_build_id": _read_meta_build_id(index) or "unknown",
            "expected_build_id": os.getenv("INSIGHTFLOW_EXPECTED_FRONTEND_BUILD_ID") or "unavailable",
            "stale_build": False,
        }

    expected = os.getenv("INSIGHTFLOW_EXPECTED_FRONTEND_BUILD_ID") or _hash_build(bundle)
    disk_build_id = _read_meta_build_id(index)
    served = (client_build_id or disk_build_id or "unknown").strip()
    stale = bool(expected and served != expected)
    return {
        "status": "stale" if stale else "healthy",
        "detail_analysis_build_id": served,
        "expected_build_id": expected or "unavailable",
        "stale_build": stale,
    }


def _recovery(frontend: dict[str, Any], services: dict[str, str], startup: dict[str, str]) -> list[dict[str, Any]]:
    actions: list[dict[str, Any]] = []

    def add(action_id: str, severity: str, title: str, action: str, automatic: bool = False) -> None:
        actions.append({"id": action_id, "severity": severity, "title": title, "action": action, "automatic": automatic})

    if frontend["status"] == "stale":
        add("frontend_stale", "warning", "Detail Analysis build is stale", "Rebuild the Flutter Detail Analysis frontend and restart the backend.")
    elif frontend["status"] == "unavailable":
        add("frontend_missing", "error", "Detail Analysis build is missing", "Build the Flutter Detail Analysis frontend into frontend/flutter_detail.")

    for name, status in services.items():
        if status != "healthy":
            title = name.replace("_", " ").title() + " is unavailable"
            add(f"{name}_unavailable", "error", title, f"Restart InsightFlow and check the {name.replace('_', ' ')} service.")

    if startup.get("privacy") != "healthy":
        add("privacy_configuration", "error", "Privacy configuration is invalid", "Restore the local-only privacy configuration and restart InsightFlow.")
    return actions


def build_diagnostics(client_build_id: str | None = None) -> dict[str, Any]:
    services: dict[str, str] = {}
    service_errors: dict[str, str] = {}
    for name, (module_name, symbol) in REQUIRED_IMPORTS.items():
        status, error = _service_check(module_name, symbol)
        services[name] = status
        if error:
            service_errors[name] = error

    startup = {
        "python": "healthy",
        "privacy": "healthy" if isinstance(LOCAL_ONLY, bool) else "unavailable",
        **{name: status for name, status in services.items()},
    }
    frontend = _frontend_status(client_build_id)
    recovery = _recovery(frontend, services, startup)
    healthy = frontend["status"] == "healthy" and all(value == "healthy" for value in services.values()) and startup["privacy"] == "healthy"

    return {
        "success": True,
        "response_type": "system_diagnostics",
        "overall_status": "healthy" if healthy else "degraded",
        "backend": {
            "status": "healthy",
            "version": os.getenv("INSIGHTFLOW_VERSION", "local"),
            "commit": os.getenv("BUILD_GIT_SHA", "working-tree")[:40],
            "started_at": STARTED_AT.isoformat(),
            "uptime_seconds": int(max(0, time.monotonic() - _START_MONOTONIC)),
        },
        "frontend": frontend,
        "services": {
            **services,
            "analysis_engine": services["detail_analysis"],
        },
        "privacy": {
            "local_dataset_processing": True,
            "raw_dataset_external_transmission": not LOCAL_ONLY,
            "metadata_only_ai_mode": bool(LOCAL_ONLY),
        },
        "recovery": recovery,
        "_internal": {"service_errors": service_errors} if os.getenv("INSIGHTFLOW_DIAGNOSTICS_DEBUG") == "1" else {},
    }


def run_startup_self_check() -> dict[str, str]:
    """Lightweight startup checks; never processes datasets."""
    index, bundle, bootstrap = _frontend_build_files()
    frontend_ok = all(path.is_file() for path in (index, bundle, bootstrap)) and bool(_read_meta_build_id(index))
    statuses = {
        "backend": "healthy",
        "frontend": "healthy" if frontend_ok else "unavailable",
        "conversation_state": _service_check(*REQUIRED_IMPORTS["conversation_state"])[0],
        "report_engine": _service_check(*REQUIRED_IMPORTS["report_generation"])[0],
        "privacy": "healthy" if isinstance(LOCAL_ONLY, bool) else "unavailable",
    }
    logger.info("[InsightFlow] Backend: %s", "OK" if statuses["backend"] == "healthy" else "FAIL")
    logger.info("[InsightFlow] Detail Analysis frontend: %s", "OK" if statuses["frontend"] == "healthy" else "FAIL")
    logger.info("[InsightFlow] Conversation state: %s", "OK" if statuses["conversation_state"] == "healthy" else "FAIL")
    logger.info("[InsightFlow] Report engine: %s", "OK" if statuses["report_engine"] == "healthy" else "FAIL")
    logger.info("[InsightFlow] Privacy guard: %s", "OK" if statuses["privacy"] == "healthy" else "FAIL")
    if all(value == "healthy" for value in statuses.values()):
        logger.info("[InsightFlow] Ready: http://127.0.0.1:8000/ui/")
    else:
        logger.warning("[InsightFlow] Ready with degraded services; run /v1/system/diagnostics for recovery guidance.")
    return statuses
