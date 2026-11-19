import base64
import hashlib
import os
import threading
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from core.excel_handoff_store import approve, bind_browser, candidate, claim, complete, create, digest, retry, cancel, status

DATABASE_URL = os.environ.get("EXCEL_HANDOFF_TEST_DATABASE_URL")
if not DATABASE_URL:
    pytest.skip("requires the dedicated PostgreSQL Excel handoff service", allow_module_level=True)
ROOT = Path(__file__).parents[2]


@pytest.fixture(scope="session")
def engine():
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    with engine.begin() as connection:
        connection.exec_driver_sql("""
          DO $$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
          END $$;
        """)
        connection.exec_driver_sql((ROOT / "migrations/0037_excel_auth_handoff.sql").read_text())
        connection.exec_driver_sql((ROOT / "migrations/0038_excel_auth_pairing.sql").read_text())
    yield engine
    with engine.begin() as connection:
        connection.exec_driver_sql("DROP SCHEMA excel_handoff CASCADE")
    engine.dispose()


@pytest.fixture(autouse=True)
def secrets(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY",
                       base64.urlsafe_b64encode(b"excel-handoff-test-key-32-bytes!").decode())
    monkeypatch.setenv("INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY", "p" * 48)


@pytest.fixture
def session(engine):
    return sessionmaker(bind=engine, expire_on_commit=False)


def make_transaction(Session):
    tx = uuid4()
    caps = {key: key + "-secret-" + ("x" * 48)
            for key in ("claim", "completion", "status", "approval", "cancel", "retry")}
    code = "0123-4567-89AB-CDEF"
    with Session.begin() as db:
        assert create(db, tx, caps, code, "instance-identifier-0001", hashlib.sha256(str(tx).encode()).digest())
    return tx, caps, code


def prepare_approved(Session, tx, caps, code, browser, uid):
    with Session.begin() as db:
        assert bind_browser(db, tx, code, browser, uuid4()) == 1
    with Session.begin() as db:
        assert candidate(db, tx, browser, 1, uuid4(), uid, "person@example.com")
    with Session.begin() as db:
        assert approve(db, tx, caps["approval"], uid, 1, "approve", uuid4())


def test_candidate_approval_and_wrong_account_rejection(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "b" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert not complete(db, tx, browser, 1, uuid4(),
                            "00000000-0000-0000-0000-000000000002", "refresh-token")
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")


def test_one_time_claim_is_serialized_by_postgres(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "c" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")
    barrier = threading.Barrier(2)
    results = []
    def worker():
        with session.begin() as db:
            barrier.wait()
            results.append(claim(db, tx, caps["claim"]))
    threads = [threading.Thread(target=worker) for _ in range(2)]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    assert sorted(value is not None for value in results) == [False, True]
    assert next(value for value in results if value) == "refresh-token"
    with session.begin() as db:
        row = db.execute(text("SELECT status,ciphertext FROM excel_handoff.transactions WHERE id=:id"),
                         {"id": tx}).one()
    assert row.status == "claimed" and row.ciphertext is None


def test_concurrent_create_rate_limit_is_atomic(session):
    ip = hashlib.sha256(b"concurrent-rate-limit-test-ip").digest()
    barrier = threading.Barrier(11)
    results = []
    def worker(index):
        values = {name: name + str(index) + "-secret-" + ("x" * 40)
                  for name in ("claim", "completion", "status", "approval", "cancel", "retry")}
        with session.begin() as db:
            barrier.wait()
            results.append(create(db, uuid4(), values, "0123-4567-89AB-CDEF",
                                  "parallel-instance-" + str(index), ip))
    threads = [threading.Thread(target=worker, args=(index,)) for index in range(11)]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    assert results.count(True) == 10
    assert results.count(False) == 1


def test_pairing_attempt_limit(session):
    tx, _, _ = make_transaction(session)
    for index in range(5):
        with session.begin() as db:
            assert bind_browser(db, tx, "FFFF-FFFF-FFFF-FFFF",
                                "browser-" + str(index) + "x" * 40, uuid4()) is None
    with session.begin() as db:
        attempts = db.execute(text("SELECT pairing_attempts FROM excel_handoff.transactions WHERE id=:id"),
                              {"id": tx}).scalar_one()
    assert attempts == 5


def test_claim_capability_is_authority_not_excel_instance_id(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "d" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")
    with session.begin() as db:
        assert claim(db, tx, caps["claim"]) == "refresh-token"


def test_create_idempotency_key_and_rate_limit(session):
    key = "excel-create-request-0123456789"
    tx = uuid4()
    caps = {name: name + "-secret-" + ("x" * 48)
            for name in ("claim", "completion", "status", "approval", "cancel", "retry")}
    code = "0123-4567-89AB-CDEF"
    ip = hashlib.sha256(b"idempotency-test-ip").digest()
    with session.begin() as db:
        assert create(db, tx, caps, code, "excel-instance-000001", ip, key) is True
    with session.begin() as db:
        assert create(db, uuid4(), caps, code, "excel-instance-000002", ip, key) == "duplicate"
    with session.begin() as db:
        count = db.execute(text("""
          SELECT count(*) FROM excel_handoff.transactions
          WHERE create_idempotency_digest=:key
        """), {"key": digest(key)}).scalar_one()
    assert count == 1

    limited_ip = hashlib.sha256(b"rate-limit-test-ip").digest()
    for index in range(10):
        values = {name: name + str(index) + "-x" * 40
                  for name in ("claim", "completion", "status", "approval", "cancel", "retry")}
        with session.begin() as db:
            assert create(db, uuid4(), values, code, "rate-instance-" + str(index), limited_ip)
    with session.begin() as db:
        values = {name: name + "-limit-x" * 8
                  for name in ("claim", "completion", "status", "approval", "cancel", "retry")}
        assert create(db, uuid4(), values, code, "rate-instance-over", limited_ip) is False


def test_pairing_expiration_and_generation_retry_invalidate_old_browser(session):
    tx, caps, code = make_transaction(session)
    with session.begin() as db:
        db.execute(text("""
          UPDATE excel_handoff.transactions
          SET pairing_expires_at=clock_timestamp()-interval '1 second'
          WHERE id=:id
        """), {"id": tx})
    with session.begin() as db:
        assert bind_browser(db, tx, code, "old-browser-" + "x" * 40, uuid4()) is None

    # A fresh transaction demonstrates a valid browser bind followed by retry.
    tx2, caps2, code2 = make_transaction(session)
    old_browser = "old-browser-" + "a" * 40
    with session.begin() as db:
        assert bind_browser(db, tx2, code2, old_browser, uuid4()) == 1
    new_code = "ABCD-EFGH-JKMN-PQRS"
    with session.begin() as db:
        assert retry(db, tx2, caps2["retry"], new_code, uuid4()) == 2
    with session.begin() as db:
        assert not candidate(db, tx2, old_browser, 1, uuid4(),
                             "00000000-0000-0000-0000-000000000001", "old@example.com")
    new_browser = "new-browser-" + "b" * 40
    with session.begin() as db:
        assert bind_browser(db, tx2, new_code, new_browser, uuid4()) == 2
    with session.begin() as db:
        assert not candidate(db, tx2, new_browser, 1, uuid4(),
                             "00000000-0000-0000-0000-000000000001", "old@example.com")
    with session.begin() as db:
        assert candidate(db, tx2, new_browser, 2, uuid4(),
                         "00000000-0000-0000-0000-000000000002", "new@example.com")


def test_cancel_clears_staged_refresh_token(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "z" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")
    with session.begin() as db:
        assert cancel(db, tx, caps["cancel"])
    with session.begin() as db:
        row = db.execute(text("SELECT status,ciphertext FROM excel_handoff.transactions WHERE id=:id"),
                         {"id": tx}).one()
        assert row.status == "cancelled" and row.ciphertext is None
        assert claim(db, tx, caps["claim"]) is None



def test_status_expiry_clears_completed_ciphertext(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "s" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")
        db.execute(text("UPDATE excel_handoff.transactions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=:id"),
                   {"id": tx})
    with session.begin() as db:
        result = status(db, tx, caps["status"])
        assert result["status"] == "expired"
    with session.begin() as db:
        row = db.execute(text("SELECT status,ciphertext FROM excel_handoff.transactions WHERE id=:id"),
                         {"id": tx}).one()
    assert row.status == "expired" and row.ciphertext is None


def test_expiry_clears_unclaimed_ciphertext(session):
    tx, caps, code = make_transaction(session)
    browser = "browser-" + "e" * 48
    uid = "00000000-0000-0000-0000-000000000001"
    prepare_approved(session, tx, caps, code, browser, uid)
    with session.begin() as db:
        assert complete(db, tx, browser, 1, uuid4(), uid, "refresh-token")
        db.execute(text("UPDATE excel_handoff.transactions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=:id"),
                   {"id": tx})
        from core.excel_handoff_store import cleanup
        cleanup(db)
    with session.begin() as db:
        row = db.execute(text("SELECT status,ciphertext FROM excel_handoff.transactions WHERE id=:id"),
                         {"id": tx}).one()
    assert row.status == "expired" and row.ciphertext is None
