import json
import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text


MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "migrations"
    / "0040_password_verification_attempt_protection.sql"
)


def test_password_verification_hook_is_private_and_atomic_on_disposable_postgres():
    database_url = os.environ.get("AUTHZ_TEST_DATABASE_URL", "").strip()
    if not database_url:
        pytest.skip(
            "AUTHZ_TEST_DATABASE_URL is only configured in the disposable PostgreSQL CI job."
        )

    engine = create_engine(
        database_url,
        future=True,
        pool_size=24,
        max_overflow=8,
    )
    try:
        with engine.begin() as conn:
            conn.exec_driver_sql("""
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
                            EXECUTE format('CREATE ROLE %%I NOLOGIN', role_name);
                        END IF;
                    END LOOP;
                END;
                $roles$;
            """)
            conn.exec_driver_sql("CREATE SCHEMA IF NOT EXISTS auth")
            conn.exec_driver_sql("""
                CREATE TABLE IF NOT EXISTS auth.users (
                    id UUID PRIMARY KEY
                )
            """)
            conn.exec_driver_sql(MIGRATION.read_text(encoding="utf-8"))

            permissions = conn.execute(text("""
                SELECT
                    c.relrowsecurity,
                    has_table_privilege('anon', c.oid, 'SELECT') AS anon_select,
                    has_table_privilege('authenticated', c.oid, 'SELECT') AS authenticated_select,
                    has_table_privilege('service_role', c.oid, 'SELECT') AS service_role_select,
                    has_table_privilege('supabase_auth_admin', c.oid, 'SELECT') AS auth_admin_select
                FROM pg_class c
                WHERE c.oid = 'public.password_failed_verification_attempts'::regclass
            """)).mappings().one()
            assert permissions["relrowsecurity"] is True
            assert permissions["anon_select"] is False
            assert permissions["authenticated_select"] is False
            assert permissions["service_role_select"] is False
            assert permissions["auth_admin_select"] is True

            function_permissions = conn.execute(text("""
                SELECT
                    has_function_privilege(
                        'anon',
                        'public.insightflow_password_verification_attempt(jsonb)',
                        'EXECUTE'
                    ) AS anon_execute,
                    has_function_privilege(
                        'authenticated',
                        'public.insightflow_password_verification_attempt(jsonb)',
                        'EXECUTE'
                    ) AS authenticated_execute,
                    has_function_privilege(
                        'service_role',
                        'public.insightflow_password_verification_attempt(jsonb)',
                        'EXECUTE'
                    ) AS service_role_execute,
                    has_function_privilege(
                        'supabase_auth_admin',
                        'public.insightflow_password_verification_attempt(jsonb)',
                        'EXECUTE'
                    ) AS auth_admin_execute
            """)).mappings().one()
            assert function_permissions["anon_execute"] is False
            assert function_permissions["authenticated_execute"] is False
            assert function_permissions["service_role_execute"] is False
            assert function_permissions["auth_admin_execute"] is True

            function_settings = conn.execute(text("""
                SELECT prosecdef, proconfig
                FROM pg_proc
                WHERE oid = 'public.insightflow_password_verification_attempt(jsonb)'::regprocedure
            """)).mappings().one()
            assert function_settings["prosecdef"] is False
            assert 'search_path=""' in (function_settings["proconfig"] or [])

        first_user = uuid.uuid4()
        with engine.begin() as conn:
            conn.execute(
                text("INSERT INTO auth.users(id) VALUES (:user_id)"),
                {"user_id": first_user},
            )

        def invoke_hook(user_id, valid):
            with engine.begin() as conn:
                conn.exec_driver_sql("SET ROLE supabase_auth_admin")
                try:
                    return conn.execute(
                        text("""
                            SELECT public.insightflow_password_verification_attempt(
                                CAST(:event AS jsonb)
                            )
                        """),
                        {
                            "event": json.dumps(
                                {"user_id": str(user_id), "valid": valid}
                            )
                        },
                    ).scalar_one()
                finally:
                    conn.exec_driver_sql("RESET ROLE")

        def failed_attempt(_):
            return invoke_hook(first_user, False)

        # Concurrent requests must all be counted by the single atomic upsert.
        with ThreadPoolExecutor(max_workers=20) as executor:
            results = list(executor.map(failed_attempt, range(20)))

        assert sum(result.get("decision") == "continue" for result in results) == 4
        assert sum(
            result.get("error", {}).get("http_code") == 429 for result in results
        ) == 16

        with engine.connect() as conn:
            counter = conn.execute(text("""
                SELECT failure_count, blocked_until
                FROM public.password_failed_verification_attempts
                WHERE user_id = :user_id
            """), {"user_id": first_user}).mappings().one()
        assert counter["failure_count"] == 20
        assert counter["blocked_until"] is not None

        # A correct password is allowed even while a cooldown exists and resets
        # the failed-attempt state. The hook only receives this event after Auth
        # has already verified the submitted password.
        success = invoke_hook(first_user, True)
        assert success == {"decision": "continue"}

        with engine.connect() as conn:
            remaining = conn.execute(text("""
                SELECT count(*)
                FROM public.password_failed_verification_attempts
                WHERE user_id = :user_id
            """), {"user_id": first_user}).scalar_one()
        assert remaining == 0

        # After reset, a single wrong password starts a fresh 15-minute window.
        with engine.begin() as conn:
            fresh = conn.execute(
                text("""
                    SELECT public.insightflow_password_verification_attempt(
                        CAST(:event AS jsonb)
                    )
                """),
                {
                    "event": json.dumps(
                        {"user_id": str(first_user), "valid": False}
                    )
                },
            ).scalar_one()
        assert fresh == {"decision": "continue"}

        # Verify that the cooldown escalates at the documented thresholds.
        escalation_user = uuid.uuid4()
        with engine.begin() as conn:
            conn.execute(
                text("INSERT INTO auth.users(id) VALUES (:user_id)"),
                {"user_id": escalation_user},
            )

        for attempt_number in range(1, 13):
            result = invoke_hook(escalation_user, False)
            if attempt_number < 5:
                assert result == {"decision": "continue"}
            else:
                assert result.get("error", {}).get("http_code") == 429

            if attempt_number in {5, 8, 12}:
                with engine.connect() as conn:
                    remaining_seconds = conn.execute(text("""
                        SELECT EXTRACT(
                            EPOCH FROM (blocked_until - clock_timestamp())
                        )
                        FROM public.password_failed_verification_attempts
                        WHERE user_id = :user_id
                    """), {"user_id": escalation_user}).scalar_one()

                lower, upper = {
                    5: (45, 75),
                    8: (270, 330),
                    12: (840, 960),
                }[attempt_number]
                assert lower <= float(remaining_seconds) <= upper

        # Even during a cooldown, a genuinely verified password can sign in.
        assert invoke_hook(escalation_user, True) == {"decision": "continue"}
    finally:
        engine.dispose()
