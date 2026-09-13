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
