"""Synthetic authorization acceptance tests against the real FastAPI stack.

These tests intentionally do not replace the provider, middleware, routes, or
authorization service.  They require the dedicated disposable PostgreSQL
service used by CI and write observed HTTP results to the acceptance evidence
file.  A missing database is a skipped, explicitly reported environment
blocker; SQLite and non-local database URLs are refused.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import urlsplit

import pytest
from fastapi.testclient import TestClient


DATABASE_URL = os.getenv("AUTHZ_TEST_DATABASE_URL", "").strip()
EVIDENCE = Path(__file__).parents[2] / "docs" / "oracle-authorization-acceptance-evidence.json"


def _assert_disposable_postgres() -> None:
    parsed = urlsplit(DATABASE_URL)
    assert parsed.scheme in {"postgresql", "postgresql+psycopg", "postgres"}, (
        "AUTHZ_TEST_DATABASE_URL must be PostgreSQL"
    )
    assert parsed.hostname in {"localhost", "127.0.0.1", "::1", "postgres"}, (
        "acceptance tests only allow a local disposable PostgreSQL host"
    )
    assert parsed.path.lstrip("/") == "insightflow_authz_test", (
        "acceptance tests require the dedicated insightflow_authz_test database"
    )


pytestmark = pytest.mark.skipif(
    not DATABASE_URL,
    reason=(
        "UNVERIFIED: set AUTHZ_TEST_DATABASE_URL to a disposable local "
        "PostgreSQL 16 database named insightflow_authz_test"
    ),
)


@pytest.fixture(scope="module")
def client():
    _assert_disposable_postgres()
    os.environ.setdefault("AUTHN_PROVIDER_MODE", "supabase")
    os.environ.setdefault("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    os.environ["DATABASE_URL"] = DATABASE_URL
    from main import app

    with TestClient(app) as test_client:
        yield test_client


def _record(name: str, response) -> None:
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    existing = json.loads(EVIDENCE.read_text(encoding="utf-8")) if EVIDENCE.exists() else {}
    existing.setdefault("observations", {})[name] = {
        "status": response.status_code,
        "detail": response.json().get("detail") if response.headers.get("content-type", "").startswith("application/json") else None,
    }
    EVIDENCE.write_text(json.dumps(existing, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@pytest.mark.parametrize(
    ("name", "method", "path"),
    [
        ("missing_bearer_managed_upload", "post", "/v1/managed-datasets"),
        ("missing_bearer_managed_download", "get", "/v1/managed-datasets/dataset-1/download"),
        ("missing_bearer_managed_rows", "get", "/v1/managed-datasets/dataset-1/working-copies/copy-1/rows"),
        ("missing_bearer_conversation", "post", "/v1/chat/plan"),
        ("missing_bearer_detail_analysis", "post", "/v2/detail-analysis"),
        ("missing_bearer_power_bi", "post", "/powerbi/detail-analysis"),
    ],
)
def test_missing_bearer_is_rejected_by_real_middleware(client, name, method, path):
    response = getattr(client, method)(path)
    _record(name, response)
    assert response.status_code == 401


def test_diagnostics_is_reached_through_real_application(client):
    response = client.get("/v1/system/diagnostics")
    _record("diagnostics", response)
    assert response.status_code == 200
    assert "token" not in response.text.lower()

