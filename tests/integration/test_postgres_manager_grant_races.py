"""PostgreSQL integration coverage for proposal publication and grant races.

Set INSIGHTFLOW_TEST_POSTGRES_URL to a disposable PostgreSQL database to run these
tests. Each test creates and drops an isolated schema; no production schema is used.
"""
from __future__ import annotations

import os
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import create_engine, text


POSTGRES_URL = os.getenv("INSIGHTFLOW_TEST_POSTGRES_URL", "").strip()
pytestmark = pytest.mark.skipif(
    not POSTGRES_URL,
    reason="INSIGHTFLOW_TEST_POSTGRES_URL is not configured for PostgreSQL integration tests",
)


@pytest.fixture()
def pg_schema():
    engine = create_engine(POSTGRES_URL, pool_size=5, max_overflow=5)
    schema = "if_grant_test_" + uuid.uuid4().hex
    with engine.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA "{schema}"'))
        conn.execute(text(f'SET search_path TO "{schema}"'))
        conn.execute(text("""
            CREATE TABLE manager_dataset_upload_grants (
                grant_id text PRIMARY KEY,
                revoked_at timestamptz
            )
        """))
        conn.execute(text("""
            CREATE TABLE proposals (
                proposal_id text PRIMARY KEY,
                grant_id text NOT NULL REFERENCES manager_dataset_upload_grants(grant_id),
                status text NOT NULL CHECK (status IN ('pending','approved','stale','rejected'))
            )
        """))
        conn.execute(text("""
            CREATE TABLE datasets (
                dataset_id text PRIMARY KEY,
                status text NOT NULL,
                current_version_id text
            )
        """))
        conn.execute(text("""
            CREATE TABLE dataset_authorization (
                dataset_id text PRIMARY KEY REFERENCES datasets(dataset_id)
            )
        """))
        conn.execute(text("""
            CREATE TABLE audit_events (
                event_id text PRIMARY KEY,
                proposal_id text NOT NULL REFERENCES proposals(proposal_id)
            )
        """))
        conn.execute(text("INSERT INTO manager_dataset_upload_grants VALUES ('g1', NULL)"))
        conn.execute(text("INSERT INTO proposals VALUES ('p1', 'g1', 'pending')"))
        conn.execute(text("INSERT INTO datasets VALUES ('d1', 'processing', NULL)"))
    try:
        yield engine, schema
    finally:
        with engine.begin() as conn:
            conn.execute(text(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'))
        engine.dispose()


def _connection(engine, schema):
    conn = engine.connect()
    conn.execute(text(f'SET search_path TO "{schema}"'))
    conn.commit()
    return conn


def test_postgres_first_publication_and_audit_are_one_transaction(pg_schema):
    engine, schema = pg_schema
    with _connection(engine, schema) as conn:
        trans = conn.begin()
        conn.execute(text("UPDATE datasets SET status='ready', current_version_id='v1' WHERE dataset_id='d1'"))
        conn.execute(text("INSERT INTO dataset_authorization VALUES ('d1')"))
        # Simulate an audit-write failure after publication mutations.
        with pytest.raises(Exception):
            conn.execute(text("INSERT INTO audit_events VALUES ('e1', 'missing-proposal')"))
        trans.rollback()
    with _connection(engine, schema) as conn:
        row = conn.execute(text("SELECT status, current_version_id FROM datasets WHERE dataset_id='d1'")).one()
        acl = conn.execute(text("SELECT count(*) FROM dataset_authorization WHERE dataset_id='d1'")).scalar_one()
        assert tuple(row) == ("processing", None)
        assert acl == 0


def test_postgres_concurrent_approval_allows_only_one_decision(pg_schema):
    engine, schema = pg_schema
    barrier = threading.Barrier(2)

    def approve():
        with _connection(engine, schema) as conn:
            with conn.begin():
                barrier.wait(timeout=5)
                row = conn.execute(text(
                    "SELECT status FROM proposals WHERE proposal_id='p1' FOR UPDATE"
                )).one()
                if row.status != "pending":
                    return "already-decided"
                conn.execute(text("UPDATE proposals SET status='approved' WHERE proposal_id='p1'"))
                return "approved"

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [pool.submit(approve), pool.submit(approve)]
        values = [future.result(timeout=15) for future in results]
    assert sorted(values) == ["already-decided", "approved"]
    with _connection(engine, schema) as conn:
        assert conn.execute(text("SELECT status FROM proposals WHERE proposal_id='p1'")).scalar_one() == "approved"


def test_postgres_revocation_wins_before_approval_revalidates_grant(pg_schema):
    engine, schema = pg_schema
    grant_locked = threading.Event()
    allow_revoke_commit = threading.Event()

    def revoke():
        with _connection(engine, schema) as conn:
            with conn.begin():
                conn.execute(text("SELECT grant_id FROM manager_dataset_upload_grants WHERE grant_id='g1' FOR UPDATE")).one()
                conn.execute(text("UPDATE manager_dataset_upload_grants SET revoked_at=now() WHERE grant_id='g1'"))
                grant_locked.set()
                assert allow_revoke_commit.wait(timeout=5)

    def approve():
        assert grant_locked.wait(timeout=5)
        with _connection(engine, schema) as conn:
            with conn.begin():
                # This blocks until revocation commits, then must not see an active grant.
                row = conn.execute(text("""
                    SELECT grant_id FROM manager_dataset_upload_grants
                    WHERE grant_id='g1' AND revoked_at IS NULL FOR SHARE
                """)).first()
                if row is None:
                    conn.execute(text("UPDATE proposals SET status='stale' WHERE proposal_id='p1' AND status='pending'"))
                    return "stale"
                conn.execute(text("UPDATE proposals SET status='approved' WHERE proposal_id='p1'"))
                return "approved"

    with ThreadPoolExecutor(max_workers=2) as pool:
        revoke_future = pool.submit(revoke)
        assert grant_locked.wait(timeout=5)
        approval_future = pool.submit(approve)
        allow_revoke_commit.set()
        revoke_future.result(timeout=10)
        result = approval_future.result(timeout=10)
    assert result == "stale"
    with _connection(engine, schema) as conn:
        assert conn.execute(text("SELECT status FROM proposals WHERE proposal_id='p1'")).scalar_one() == "stale"
