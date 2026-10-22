"""Real PostgreSQL coverage for the assignment index migrations.

Runs only against the disposable AUTHZ_TEST_DATABASE_URL supplied by CI. It never
reads DATABASE_URL, so production credentials cannot be selected accidentally.
"""

import os
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError

from tools.run_authz_migrations import verify_assignment_indexes


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations"
DATABASE_URL = os.environ.get("AUTHZ_TEST_DATABASE_URL", "").strip()


pytestmark = pytest.mark.skipif(
    not DATABASE_URL.startswith(("postgresql://", "postgresql+psycopg://")),
    reason="Requires a disposable PostgreSQL AUTHZ_TEST_DATABASE_URL.",
)


@pytest.fixture()
def postgres_engine():
    # CI provisions a new PostgreSQL service database for this test job.
    engine = create_engine(DATABASE_URL, future=True)
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE IF EXISTS organizational_assignments CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS organization_members CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS sections CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS locations CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS roles CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS principals CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS organizations CASCADE"))
        conn.execute(text("CREATE TABLE organizations (organization_id TEXT PRIMARY KEY)"))
        conn.execute(text("CREATE TABLE principals (principal_id TEXT PRIMARY KEY)"))
        conn.execute(text("CREATE TABLE roles (role_id TEXT PRIMARY KEY)"))
        conn.execute(text("""
            CREATE TABLE organization_members (
                organization_id TEXT NOT NULL REFERENCES organizations(organization_id),
                principal_id TEXT NOT NULL REFERENCES principals(principal_id),
                PRIMARY KEY (organization_id, principal_id)
            )
        """))
        conn.execute(text("CREATE TABLE insightflow_schema_migrations (version TEXT PRIMARY KEY)"))
    try:
        yield engine
    finally:
        engine.dispose()


def _apply_sql(engine, filename):
    sql = (MIGRATIONS / filename).read_text(encoding="utf-8")
    with engine.begin() as conn:
        conn.exec_driver_sql(sql)


def _read_index_definition(engine):
    with engine.connect() as conn:
        rows = conn.execute(text("""
            SELECT indexname, indexdef
            FROM pg_indexes
            WHERE schemaname = current_schema()
              AND tablename = 'organizational_assignments'
              AND indexname IN (
                'uq_active_manager_per_location',
                'uq_active_assignment_context'
              )
        """)).all()
    return {row[0]: row[1] for row in rows}


def _seed_assignment_parents(engine):
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO organizations VALUES ('org-a')"))
        conn.execute(text("INSERT INTO principals VALUES ('person-a'), ('person-b')"))
        conn.execute(text("INSERT INTO roles VALUES ('manager'), ('team_lead')"))
        conn.execute(text("""
            INSERT INTO organization_members (organization_id, principal_id)
            VALUES ('org-a', 'person-a'), ('org-a', 'person-b')
        """))
        conn.execute(text("""
            INSERT INTO locations (location_id, organization_id, name)
            VALUES ('branch-a', 'org-a', 'Branch A')
        """))


def test_postgres_migration_definition_allows_multiple_managers_and_rejects_duplicates(postgres_engine):
    _apply_sql(postgres_engine, "0008_organizational_structure.sql")
    _apply_sql(postgres_engine, "0030_single_active_branch_assignment.sql")
    _apply_sql(postgres_engine, "0033_allow_multiple_managers_per_location.sql")

    indexes = _read_index_definition(postgres_engine)
    assert "uq_active_manager_per_location" not in indexes
    assert "uq_active_assignment_context" in indexes
    verify_assignment_indexes(indexes)

    _seed_assignment_parents(postgres_engine)
    with postgres_engine.begin() as conn:
        conn.execute(text("""
            INSERT INTO organizational_assignments
                (assignment_id, organization_id, principal_id, location_id, role_id, status)
            VALUES
                ('assignment-a', 'org-a', 'person-a', 'branch-a', 'manager', 'active'),
                ('assignment-b', 'org-a', 'person-b', 'branch-a', 'manager', 'active')
        """))

    # Same active assignment context must remain unique, including NULL section.
    with pytest.raises(IntegrityError):
        with postgres_engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO organizational_assignments
                    (assignment_id, organization_id, principal_id, location_id, role_id, status)
                VALUES ('assignment-a-duplicate', 'org-a', 'person-a', 'branch-a', 'manager', 'active')
            """))


def test_migration_runner_skips_completed_versions_and_verifies_schema(
    postgres_engine, monkeypatch, tmp_path
):
    import shutil

    from tools import run_authz_migrations as runner

    versions = (
        "0008_organizational_structure.sql",
        "0030_single_active_branch_assignment.sql",
        "0033_allow_multiple_managers_per_location.sql",
    )
    for filename in versions:
        shutil.copyfile(MIGRATIONS / filename, tmp_path / filename)
    monkeypatch.setattr(runner, "MIGRATIONS", tmp_path)

    applied, already = runner.apply_pending(postgres_engine)
    assert applied == [filename[:-4] for filename in versions]
    assert already == []

    applied_again, already_again = runner.apply_pending(postgres_engine)
    assert applied_again == []
    assert already_again == [filename[:-4] for filename in versions]

    indexes = _read_index_definition(postgres_engine)
    assert "uq_active_manager_per_location" not in indexes
    verify_assignment_indexes(indexes)
