import base64
import os
import threading
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from core.excel_handoff_store import (
    cancel, claim, cleanup, complete, create, lock_pending_completion,
)


DATABASE_URL = os.environ.get("EXCEL_HANDOFF_TEST_DATABASE_URL", "").strip()
MIGRATION = Path(__file__).parents[2] / "migrations" / "0037_excel_auth_handoff.sql"

pytestmark = pytest.mark.skipif(
    not DATABASE_URL,
    reason="Requires EXCEL_HANDOFF_TEST_DATABASE_URL for PostgreSQL integration tests.",
)


@pytest.fixture(scope="session")
def engine():
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    with engine.begin() as connection:
        connection.exec_driver_sql("""
            DO $$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon')
                THEN CREATE ROLE anon NOLOGIN;
                END IF;
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated')
                THEN CREATE ROLE authenticated NOLOGIN;
                END IF;
            END $$;
        """)
        connection.exec_driver_sql(MIGRATION.read_text())
    yield engine
    with engine.begin() as connection:
        connection.exec_driver_sql("DROP SCHEMA excel_handoff CASCADE")
    engine.dispose()


@pytest.fixture(autouse=True)
def encryption_key(monkeypatch):
    monkeypatch.setenv(
        "INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY",
        base64.urlsafe_b64encode(b"excel-handoff-test-key-32-bytes!").decode(),
    )


def session_factory(engine):
    return sessionmaker(bind=engine, expire_on_commit=False)


def test_migration_security_and_constraints(engine):
    with engine.connect() as db:
        assert db.execute(text(
            "SELECT relrowsecurity FROM pg_class "
            "WHERE oid = 'excel_handoff.transactions'::regclass"
        )).scalar_one()
        assert db.execute(text(
            "SELECT has_schema_privilege('public', 'excel_handoff', 'USAGE')"
        )).scalar_one() is False
        assert db.execute(text(
            "SELECT has_table_privilege('public', 'excel_handoff.transactions', 'SELECT')"
        )).scalar_one() is False
        for role in ("anon", "authenticated"):
            assert db.execute(text(
                "SELECT has_schema_privilege(:role, 'excel_handoff', 'USAGE')"
            ), {"role": role}).scalar_one() is False
            assert db.execute(text(
                "SELECT has_table_privilege(:role, 'excel_handoff.transactions', 'SELECT')"
            ), {"role": role}).scalar_one() is False
        assert db.execute(text(
            "SELECT 1 FROM pg_indexes WHERE schemaname='excel_handoff' "
            "AND indexname='excel_handoff_expiry'"
        )).scalar_one() == 1


def test_create_complete_claim_is_single_use(engine):
    Session = session_factory(engine)
    transaction, claim_secret, completion_secret = uuid4(), "c" * 43, "p" * 43
    with Session.begin() as db:
        assert create(db, transaction, claim_secret, completion_secret)
        assert lock_pending_completion(db, transaction, completion_secret)
        assert complete(db, transaction, completion_secret, "refresh-token")
    with Session.begin() as db:
        assert not lock_pending_completion(db, transaction, completion_secret)
        assert claim(db, transaction, claim_secret) == "refresh-token"
    with Session.begin() as db:
        assert claim(db, transaction, claim_secret) is None


def test_two_connections_have_one_winner(engine):
    Session = session_factory(engine)
    transaction, claim_secret, completion_secret = uuid4(), "a" * 43, "b" * 43
    with Session.begin() as db:
        assert create(db, transaction, claim_secret, completion_secret)
        assert complete(db, transaction, completion_secret, "refresh-token")

    barrier = threading.Barrier(2)
    results = []

    def worker():
        with Session.begin() as db:
            barrier.wait()
            results.append(claim(db, transaction, claim_secret))

    first, second = threading.Thread(target=worker), threading.Thread(target=worker)
    first.start()
    second.start()
    first.join()
    second.join()
    assert sorted(result is not None for result in results) == [False, True]


def test_cancel_and_expiry_cannot_be_claimed(engine):
    Session = session_factory(engine)
    cancelled, expired = uuid4(), uuid4()
    for transaction in (cancelled, expired):
        with Session.begin() as db:
            assert create(db, transaction, "x" * 43, "y" * 43)
            assert complete(db, transaction, "y" * 43, "refresh-token")
    with Session.begin() as db:
        db.execute(text(
            "UPDATE excel_handoff.transactions SET status='cancelled', ciphertext=NULL "
            "WHERE id=:id"
        ), {"id": cancelled})
        db.execute(text(
            "UPDATE excel_handoff.transactions SET expires_at=clock_timestamp()-interval '1 second' "
            "WHERE id=:id"
        ), {"id": expired})
    with Session.begin() as db:
        assert claim(db, cancelled, "x" * 43) is None
        assert claim(db, expired, "x" * 43) is None


def test_rollback_does_not_create_transaction(engine):
    Session = session_factory(engine)
    transaction = uuid4()
    with pytest.raises(RuntimeError):
        with Session.begin() as db:
            assert create(db, transaction, "m" * 43, "n" * 43)
            raise RuntimeError("rollback test")
    with Session.begin() as db:
        assert db.execute(text(
            "SELECT 1 FROM excel_handoff.transactions WHERE id=:id"
        ), {"id": transaction}).scalar_one_or_none() is None


def test_cleanup_removes_expired_transactions(engine):
    Session = session_factory(engine)
    transaction = uuid4()
    with Session.begin() as db:
        assert create(db, transaction, "u" * 43, "v" * 43)
        db.execute(text(
            "UPDATE excel_handoff.transactions SET expires_at=clock_timestamp()-interval '1 second' "
            "WHERE id=:id"
        ), {"id": transaction})
        cleanup(db)
    with Session.begin() as db:
        assert db.execute(text(
            "SELECT 1 FROM excel_handoff.transactions WHERE id=:id"
        ), {"id": transaction}).scalar_one_or_none() is None


def test_completion_and_cancellation_race_has_one_committed_state(engine):
    Session = session_factory(engine)
    transaction, claim_secret, completion_secret = uuid4(), "s" * 43, "t" * 43
    with Session.begin() as db:
        assert create(db, transaction, claim_secret, completion_secret)

    barrier = threading.Barrier(2)
    outcomes = []

    def finish():
        with Session.begin() as db:
            barrier.wait()
            outcomes.append(complete(db, transaction, completion_secret, "refresh-token"))

    def abort():
        with Session.begin() as db:
            barrier.wait()
            db.execute(text(
                "UPDATE excel_handoff.transactions SET status='cancelled', ciphertext=NULL "
                "WHERE id=:id AND status='pending' RETURNING id"
            ), {"id": transaction})
            outcomes.append(True)

    first, second = threading.Thread(target=finish), threading.Thread(target=abort)
    first.start()
    second.start()
    first.join()
    second.join()
    with Session.begin() as db:
        status, ciphertext = db.execute(text(
            "SELECT status, ciphertext FROM excel_handoff.transactions WHERE id=:id"
        ), {"id": transaction}).one()
    assert status in {"completed", "cancelled"}
    assert (status == "completed") == (ciphertext is not None)


def test_claim_rollback_allows_next_claim(engine):
    Session = session_factory(engine)
    transaction, claim_secret, completion_secret = uuid4(), "g" * 43, "h" * 43
    with Session.begin() as db:
        assert create(db, transaction, claim_secret, completion_secret)
        assert complete(db, transaction, completion_secret, "refresh-token")

    with pytest.raises(RuntimeError):
        with Session.begin() as db:
            assert claim(db, transaction, claim_secret) == "refresh-token"
            raise RuntimeError("claim rollback test")
    with Session.begin() as db:
        assert claim(db, transaction, claim_secret) == "refresh-token"


def test_complete_lock_blocks_duplicate_token_rotation(engine):
    Session = session_factory(engine)
    transaction, claim_secret, completion_secret = uuid4(), "d" * 43, "e" * 43
    with Session.begin() as db:
        assert create(db, transaction, claim_secret, completion_secret)
        assert lock_pending_completion(db, transaction, completion_secret)
        assert complete(db, transaction, completion_secret, "rotated-refresh-token")
    with Session.begin() as db:
        assert not lock_pending_completion(db, transaction, completion_secret)
        cancel(db, transaction, claim_secret)
        assert claim(db, transaction, claim_secret) == "rotated-refresh-token"


def test_fastapi_http_flow_uses_postgres(engine, monkeypatch):
    from core.db import get_db
    from excel_auth_handoff import routes
    from main import app

    Session = session_factory(engine)

    def override_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    refresh_calls = []

    def rotate_refresh_token(token):
        refresh_calls.append(token)
        return "rotated-access", "rotated-refresh"

    monkeypatch.setattr(routes, "verify_supabase_access_token", lambda token: {"uid": "user-1"})
    monkeypatch.setattr(routes, "_refresh_pair", rotate_refresh_token)
    app.dependency_overrides[get_db] = override_db
    try:
        client = TestClient(app)
        transaction = str(uuid4())
        claim_secret, completion_secret = "q" * 43, "r" * 43
        response = client.post("/v1/excel-auth/handoff/create", json={
            "transaction_id": transaction,
            "claim_capability": claim_secret,
            "completion_capability": completion_secret,
        })
        assert response.status_code == 201
        response = client.post("/v1/excel-auth/handoff/complete", json={
            "transaction_id": transaction,
            "completion_capability": completion_secret,
            "access_token": "a" * 20,
            "refresh_token": "b" * 20,
        })
        assert response.status_code == 204
        duplicate = client.post("/v1/excel-auth/handoff/complete", json={
            "transaction_id": transaction,
            "completion_capability": completion_secret,
            "access_token": "a" * 20,
            "refresh_token": "b" * 20,
        })
        assert duplicate.status_code == 409
        assert refresh_calls == ["b" * 20]
        response = client.post("/v1/excel-auth/handoff/claim", json={
            "transaction_id": transaction,
            "claim_capability": claim_secret,
        })
        assert response.status_code == 200
        assert response.json() == {"refresh_token": "rotated-refresh"}
        assert client.post("/v1/excel-auth/handoff/claim", json={
            "transaction_id": transaction,
            "claim_capability": claim_secret,
        }).status_code == 404
    finally:
        app.dependency_overrides.pop(get_db, None)
