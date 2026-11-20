import pytest

from excel_auth_handoff import routes


class _Db:
    def __init__(self):
        self.rollback_calls = 0

    def rollback(self):
        self.rollback_calls += 1

    def commit(self):
        pass


def _payload():
    return routes.CompleteRequest(
        transaction_id="00000000-0000-0000-0000-000000000001",
        browser_capability="b" * 48,
        generation=1,
        request_id="00000000-0000-0000-0000-000000000002",
        access_token="a" * 40,
        refresh_token="r" * 40,
    )


def test_completion_rejects_stale_target_before_refresh(monkeypatch):
    db = _Db()
    monkeypatch.setattr(routes.store, "can_complete", lambda *args: False)
    refresh_called = False

    def refresh(_token):
        nonlocal refresh_called
        refresh_called = True
        raise AssertionError("refresh must not run for an ineligible transaction")

    monkeypatch.setattr(routes, "refresh_supabase_session", refresh)
    with pytest.raises(routes.HTTPException) as error:
        routes.complete(_payload(), db=db)

    assert error.value.status_code == 404
    assert not refresh_called
    assert db.rollback_calls >= 1


def test_completion_rejects_refreshed_uid_mismatch(monkeypatch):
    db = _Db()
    monkeypatch.setattr(routes.store, "can_complete", lambda *args: True)
    identities = iter([{"uid": "user-a"}, {"uid": "user-b"}])
    monkeypatch.setattr(routes, "verify_supabase_access_token", lambda token: next(identities))
    monkeypatch.setattr(
        routes,
        "refresh_supabase_session",
        lambda token: {"access_token": "rotated-access", "refresh_token": "rotated-refresh"},
    )
    with pytest.raises(routes.HTTPException) as error:
        routes.complete(_payload(), db=db)

    assert error.value.status_code == 401
    assert db.rollback_calls >= 1


def test_completion_persistence_failure_does_not_retry_consumed_token(monkeypatch):
    db = _Db()
    monkeypatch.setattr(routes.store, "can_complete", lambda *args: True)
    monkeypatch.setattr(routes, "verify_supabase_access_token", lambda token: {"uid": "user-a"})
    rotated = {"access_token": "rotated-access", "refresh_token": "rotated-refresh"}
    monkeypatch.setattr(routes, "refresh_supabase_session", lambda token: rotated)
    captured = {}

    def fail_complete(*args):
        captured["refresh_token"] = args[-1]
        raise RuntimeError("database unavailable")

    monkeypatch.setattr(routes.store, "complete", fail_complete)
    with pytest.raises(routes.HTTPException) as error:
        routes.complete(_payload(), db=db)

    assert error.value.status_code == 503
    assert captured["refresh_token"] == "rotated-refresh"
    assert db.rollback_calls >= 1
