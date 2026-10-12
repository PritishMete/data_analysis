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
    """Enforce test-collection boundaries and gate the external student runtime.

    The broad legacy endpoint regression suite can run with middleware auth
    disabled because its tests exercise endpoint behavior without Supabase
    credentials. Dedicated auth-boundary suites must never be collected in
    that mode; those suites run separately with auth required.
    """
    auth_required = os.environ.get("INSIGHTFLOW_AUTH_REQUIRED", "true").strip().lower() in {
        "1", "true", "yes", "on"
    }
    protected_auth_modules = {
        "test_supabase_authz_api.py",
        "test_managed_dataset_middleware.py",
        "test_office_mutation_boundary.py",
        "test_supabase_only_auth.py",
        "test_supabase_only_persistence.py",
    }
    if not auth_required:
        collected_protected = sorted({
            Path(item.nodeid.split("::", 1)[0]).name
            for item in items
            if Path(item.nodeid.split("::", 1)[0]).name in protected_auth_modules
        })
        if collected_protected:
            raise pytest.UsageError(
                "INSIGHTFLOW_AUTH_REQUIRED=false cannot collect protected authorization "
                "tests: " + ", ".join(collected_protected)
            )

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
