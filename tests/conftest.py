# tests/conftest.py
# Repository-wide fixtures plus explicit gating for external Windows
# integration tests. Repository CI must not depend on another local project.

import os
import sys
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.db import Base  # noqa: E402


@pytest.fixture()
def db_session():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    import datasets.models  # noqa: F401
    import query_history.models  # noqa: F401
    import schema_intelligence.models  # noqa: F401
    import plan_cache.models  # noqa: F401

    Base.metadata.create_all(bind=engine)
    # Authz identity lookup tables are maintained by the SQL migrations rather
    # than SQLAlchemy models, so create the minimal SQLite equivalents needed by
    # authz tests. This keeps the repository test DB aligned with production.
    from sqlalchemy import text
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS principals (
                principal_id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS identity_bindings (
                provider TEXT NOT NULL,
                provider_subject TEXT NOT NULL,
                principal_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                firebase_uid TEXT,
                PRIMARY KEY (provider, provider_subject)
            )
        """))
    SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


def pytest_collection_modifyitems(config, items):
    """Skip only the external student-runtime integration when unavailable.

    The test itself remains unchanged and therefore still executes normally
    on a Windows acceptance machine that supplies INSIGHTFLOW_STUDENT_ROOT.
    No broad test skip is used.
    """
    configured = os.environ.get("INSIGHTFLOW_STUDENT_ROOT")
    student_root = Path(configured) if configured else None
    available = bool(student_root and student_root.is_dir())
    if available:
        return

    marker = pytest.mark.skip(
        reason=(
            "External InsightFlow student runtime is unavailable in this environment; "
            "set INSIGHTFLOW_STUDENT_ROOT to the external student project root to run it."
        )
    )
    for item in items:
        if item.nodeid.endswith("tests/test_end_to_end_learning.py::test_live_student_learning_lifecycle_and_privacy"):
            item.add_marker(marker)


@pytest.fixture(autouse=True)
def _authenticated_legacy_route_tests(monkeypatch, request):
    """Give route-behavior tests a deterministic authorized test principal.

    These modules exercise analysis/business routes, not the auth boundary.
    Keep the real middleware active with a test-only bearer token and explicit
    workspace/resource context; auth-boundary tests remain untouched and must
    continue to assert rejection of missing/invalid credentials.
    """
    route_behavior_modules = {
        "test_chat_reasoning.py",
        "test_detail_upload.py",
        "test_learning_bridge.py",
        "test_memory_engine_exporters.py",
        "test_secure_excel_privacy.py",
        "test_secure_excel_query_fixes.py",
    }
    if request.node.path.name not in route_behavior_modules:
        return

    from fastapi.testclient import TestClient
    import firebase_authz.middleware as middleware
    from firebase_authz import supabase_provider

    test_token = "insightflow-ci-test-token"
    workspace_id = "workspace_ci_test"
    resource_id = "resource_ci_test"

    original_init = TestClient.__init__

    def init_with_test_identity(self, app, *args, **kwargs):
        if kwargs.get("headers") is None:
            kwargs["headers"] = {
                "Authorization": f"Bearer {test_token}",
                "X-InsightFlow-Workspace-ID": workspace_id,
                "X-InsightFlow-Resource-ID": resource_id,
            }
        original_init(self, app, *args, **kwargs)

    monkeypatch.setattr(TestClient, "__init__", init_with_test_identity)

    original_verify = middleware.verify_id_token

    def verify_test_token(token):
        if token == test_token:
            return {
                "uid": "ci-test-user",
                "sub": "ci-test-user",
                "provider": "supabase",
                "email": "ci-test@example.com",
                "email_verified": True,
            }
        return original_verify(token)

    monkeypatch.setattr(middleware, "verify_id_token", verify_test_token)

    original_authorize = middleware.authorization

    def authorize_test_user(uid, requested_workspace, action, requested_resource=None):
        if uid == "ci-test-user" and requested_workspace == workspace_id:
            return {
                "allowed": True,
                "uid": uid,
                "workspace_id": requested_workspace,
                "resource_id": requested_resource,
                "action": action,
            }
        return original_authorize(uid, requested_workspace, action, requested_resource)

    monkeypatch.setattr(middleware, "authorization", authorize_test_user)

    original_provider_authorize = supabase_provider.authorize

    def authorize_test_provider(claims, requested_workspace, action, requested_resource=None):
        if claims.get("uid") == "ci-test-user" and requested_workspace == workspace_id:
            return {
                "allowed": True,
                "uid": "ci-test-user",
                "workspace_id": requested_workspace,
                "resource_id": requested_resource,
                "action": action,
            }
        return original_provider_authorize(
            claims, requested_workspace, action, requested_resource
        )

    monkeypatch.setattr(supabase_provider, "authorize", authorize_test_provider)
