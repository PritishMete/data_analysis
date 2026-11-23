import json
import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = [
    ROOT / "migrations" / "0040_password_verification_attempt_protection.sql",
    ROOT / "migrations" / "0041_password_verification_rolling_window.sql",
]


@pytest.fixture()
def auth_hook_db():
    database_url = os.environ.get("AUTHZ_TEST_DATABASE_URL", "").strip()
    if not database_url:
        pytest.fail(
            "AUTHZ_TEST_DATABASE_URL is required; authentication security integration "
            "tests must never silently skip."
        )

    engine = create_engine(
        database_url,
        future=True,
        pool_size=40,
        max_overflow=60,
        pool_pre_ping=True,
    )
    try:
        with engine.begin() as conn:
            conn.exec_driver_sql(
                """
                DO $roles$
                DECLARE
                    role_name text;
                BEGIN
                    FOREACH role_name IN ARRAY ARRAY[
                        'anon', 'authenticated', 'service_role', 'supabase_auth_admin'
                    ]
                    LOOP
                        IF NOT EXISTS (
                            SELECT 1 FROM pg_roles WHERE rolname = role_name
                        ) THEN
                            EXECUTE format('CREATE ROLE %I NOLOGIN', role_name);
                        END IF;
                    END LOOP;
                END;
                $roles$;
                """
            )
            conn.exec_driver_sql("CREATE SCHEMA IF NOT EXISTS auth")
            conn.exec_driver_sql(
                """
                CREATE TABLE IF NOT EXISTS auth.users (
                    id UUID PRIMARY KEY
                )
                """
            )
            for migration in MIGRATIONS:
                conn.exec_driver_sql(migration.read_text(encoding="utf-8"))

        yield engine
    finally:
        engine.dispose()


def create_user(engine):
    user_id = uuid.uuid4()
    with engine.begin() as conn:
        conn.execute(
            text("INSERT INTO auth.users(id) VALUES (:user_id)"),
            {"user_id": user_id},
        )
    return user_id


def invoke_hook(engine, user_id, valid):
    with engine.begin() as conn:
        conn.exec_driver_sql("SET ROLE supabase_auth_admin")
        try:
            return conn.execute(
                text(
                    """
                    SELECT public.insightflow_password_verification_attempt(
                        CAST(:event AS jsonb)
                    )
                    """
                ),
                {
                    "event": json.dumps(
                        {"user_id": str(user_id), "valid": valid}
                    )
                },
            ).scalar_one()
        finally:
            conn.exec_driver_sql("RESET ROLE")


def read_counter(engine, user_id):
    with engine.connect() as conn:
        return conn.execute(
            text(
                """
                SELECT failure_count, blocked_until,
                       pg_catalog.cardinality(failure_timestamps) AS timestamp_count
                FROM public.password_failed_verification_attempts
                WHERE user_id = :user_id
                """
            ),
            {"user_id": user_id},
        ).mappings().one_or_none()


def test_hook_permissions_and_function_hardening(auth_hook_db):
    engine = auth_hook_db
    with engine.connect() as conn:
        permissions = conn.execute(
            text(
                """
                SELECT
                    c.relrowsecurity,
                    has_table_privilege('anon', c.oid, 'SELECT') AS anon_select,
                    has_table_privilege('anon', c.oid, 'INSERT') AS anon_insert,
                    has_table_privilege('anon', c.oid, 'UPDATE') AS anon_update,
                    has_table_privilege('anon', c.oid, 'DELETE') AS anon_delete,
                    has_table_privilege('authenticated', c.oid, 'SELECT') AS authenticated_select,
                    has_table_privilege('authenticated', c.oid, 'INSERT') AS authenticated_insert,
                    has_table_privilege('authenticated', c.oid, 'UPDATE') AS authenticated_update,
                    has_table_privilege('authenticated', c.oid, 'DELETE') AS authenticated_delete,
                    has_table_privilege('service_role', c.oid, 'SELECT') AS service_role_select,
                    has_table_privilege('service_role', c.oid, 'INSERT') AS service_role_insert,
                    has_table_privilege('service_role', c.oid, 'UPDATE') AS service_role_update,
                    has_table_privilege('service_role', c.oid, 'DELETE') AS service_role_delete,
                    has_table_privilege('supabase_auth_admin', c.oid, 'SELECT') AS auth_admin_select,
                    has_table_privilege('supabase_auth_admin', c.oid, 'INSERT') AS auth_admin_insert,
                    has_table_privilege('supabase_auth_admin', c.oid, 'UPDATE') AS auth_admin_update,
                    has_table_privilege('supabase_auth_admin', c.oid, 'DELETE') AS auth_admin_delete
                FROM pg_class c
                WHERE c.oid = 'public.password_failed_verification_attempts'::regclass
                """
            )
        ).mappings().one()

        assert permissions["relrowsecurity"] is True
        for key, value in permissions.items():
            if key.endswith(("_select", "_insert", "_update", "_delete")) and not key.startswith("auth_admin"):
                assert value is False, key
        assert permissions["auth_admin_select"] is True
        assert permissions["auth_admin_insert"] is True
        assert permissions["auth_admin_update"] is True
        assert permissions["auth_admin_delete"] is True

        columns = conn.execute(
            text(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'password_failed_verification_attempts'
                """
            )
        ).scalars().all()
        assert set(columns) == {
            "user_id",
            "failure_count",
            "window_started_at",
            "last_failed_at",
            "blocked_until",
            "updated_at",
            "failure_timestamps",
        }
        assert not any(
            marker in column.casefold()
            for column in columns
            for marker in ("password", "hash", "email", "ip", "token")
        )

        function_permissions = conn.execute(
            text(
                """
                SELECT
                    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
                    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
                    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
                    has_function_privilege('supabase_auth_admin', p.oid, 'EXECUTE') AS auth_admin_execute,
                    p.prosecdef,
                    p.proconfig
                FROM pg_proc p
                WHERE p.oid = 'public.insightflow_password_verification_attempt(jsonb)'::regprocedure
                """
            )
        ).mappings().one()

    assert function_permissions["anon_execute"] is False
    assert function_permissions["authenticated_execute"] is False
    assert function_permissions["service_role_execute"] is False
    assert function_permissions["auth_admin_execute"] is True
    assert function_permissions["prosecdef"] is False
    assert 'search_path=""' in (function_permissions["proconfig"] or [])


@pytest.mark.parametrize("attempt_count", [5, 8, 12, 20, 100])
def test_concurrent_failures_are_counted_without_lost_updates(auth_hook_db, attempt_count):
    engine = auth_hook_db
    user_id = create_user(engine)

    with ThreadPoolExecutor(max_workers=attempt_count) as executor:
        results = list(
            executor.map(
                lambda _: invoke_hook(engine, user_id, False),
                range(attempt_count),
            )
        )

    allowed = sum(result.get("decision") == "continue" for result in results)
    blocked = sum(
        result.get("error", {}).get("http_code") == 429 for result in results
    )
    assert allowed == 4
    assert blocked == attempt_count - 4

    counter = read_counter(engine, user_id)
    assert counter is not None
    assert counter["failure_count"] == min(attempt_count, 12)
    assert counter["timestamp_count"] == min(attempt_count, 12)
    assert counter["blocked_until"] is not None


def test_cooldown_escalation_and_verified_password_reset(auth_hook_db):
    engine = auth_hook_db
    user_id = create_user(engine)

    for attempt_number in range(1, 13):
        result = invoke_hook(engine, user_id, False)
        if attempt_number < 5:
            assert result == {"decision": "continue"}
        else:
            assert result.get("error", {}).get("http_code") == 429

        if attempt_number in {5, 8, 12}:
            counter = read_counter(engine, user_id)
            with engine.connect() as conn:
                remaining_seconds = conn.execute(
                    text(
                        """
                        SELECT EXTRACT(EPOCH FROM (blocked_until - clock_timestamp()))
                        FROM public.password_failed_verification_attempts
                        WHERE user_id = :user_id
                        """
                    ),
                    {"user_id": user_id},
                ).scalar_one()
            lower, upper = {
                5: (45, 75),
                8: (270, 330),
                12: (840, 960),
            }[attempt_number]
            assert lower <= float(remaining_seconds) <= upper
            assert counter["failure_count"] == attempt_number

    # Supabase sends valid=true only after its own password verifier succeeds.
    assert invoke_hook(engine, user_id, True) == {"decision": "continue"}
    assert read_counter(engine, user_id) is None


def test_true_rolling_window_expires_only_attempts_older_than_15_minutes(auth_hook_db):
    engine = auth_hook_db
    expired_user = create_user(engine)
    for _ in range(4):
        assert invoke_hook(engine, expired_user, False) == {"decision": "continue"}

    with engine.begin() as conn:
        conn.execute(
            text(
                """
                UPDATE public.password_failed_verification_attempts
                SET failure_timestamps = ARRAY(
                    SELECT clock_timestamp() - INTERVAL '15 minutes' - INTERVAL '1 second'
                    FROM generate_series(1, 4)
                ),
                failure_count = 4
                WHERE user_id = :user_id
                """
            ),
            {"user_id": expired_user},
        )

    assert invoke_hook(engine, expired_user, False) == {"decision": "continue"}
    expired_counter = read_counter(engine, expired_user)
    assert expired_counter["failure_count"] == 1
    assert expired_counter["timestamp_count"] == 1

    boundary_user = create_user(engine)
    for _ in range(4):
        assert invoke_hook(engine, boundary_user, False) == {"decision": "continue"}

    with engine.begin() as conn:
        conn.execute(
            text(
                """
                UPDATE public.password_failed_verification_attempts
                SET failure_timestamps = ARRAY(
                    SELECT clock_timestamp() - INTERVAL '15 minutes' + INTERVAL '1 second'
                    FROM generate_series(1, 4)
                ),
                failure_count = 4
                WHERE user_id = :user_id
                """
            ),
            {"user_id": boundary_user},
        )

    boundary_result = invoke_hook(engine, boundary_user, False)
    assert boundary_result.get("error", {}).get("http_code") == 429
    boundary_counter = read_counter(engine, boundary_user)
    assert boundary_counter["failure_count"] == 5
    assert boundary_counter["timestamp_count"] == 5


def test_simultaneous_success_and_failure_events_are_serialized(auth_hook_db):
    engine = auth_hook_db
    user_id = create_user(engine)

    # Seed an account near the threshold, then race a verified success against
    # one failure. The final state must correspond to one serialized order:
    # either success clears the row, or the later failure leaves exactly one.
    for _ in range(4):
        assert invoke_hook(engine, user_id, False) == {"decision": "continue"}

    with ThreadPoolExecutor(max_workers=2) as executor:
        success_future = executor.submit(invoke_hook, engine, user_id, True)
        failure_future = executor.submit(invoke_hook, engine, user_id, False)
        assert success_future.result() == {"decision": "continue"}
        failure_result = failure_future.result()

    # Either event may acquire the per-user advisory lock first. A failure
    # before success can be recorded and then cleared; a failure after success
    # leaves exactly one recent failure. Both outcomes are safe.
    assert failure_result == {"decision": "continue"} or (
        failure_result.get("error", {}).get("http_code") == 429
    )
    counter = read_counter(engine, user_id)
    assert counter is None or (
        counter["failure_count"] == 1 and counter["timestamp_count"] == 1
    )


def test_malformed_events_are_rejected_without_sql_execution(auth_hook_db):
    engine = auth_hook_db
    malformed_events = [
        None,
        [],
        {},
        {"user_id": "", "valid": False},
        {"user_id": "not-a-uuid", "valid": False},
        {"user_id": "00000000-0000-0000-0000-000000000001", "valid": "not-a-bool"},
        {
            "user_id": "00000000-0000-0000-0000-000000000001'); DROP TABLE auth.users; --",
            "valid": False,
        },
    ]

    with engine.begin() as conn:
        conn.exec_driver_sql("SET ROLE supabase_auth_admin")
        try:
            for event in malformed_events:
                result = conn.execute(
                    text(
                        """
                        SELECT public.insightflow_password_verification_attempt(
                            CAST(:event AS jsonb)
                        )
                        """
                    ),
                    {"event": json.dumps(event)},
                ).scalar_one()
                assert result.get("error", {}).get("http_code") == 400
        finally:
            conn.exec_driver_sql("RESET ROLE")

    with engine.connect() as conn:
        assert conn.execute(
            text("SELECT to_regclass('auth.users')")
        ).scalar_one() == "auth.users"
