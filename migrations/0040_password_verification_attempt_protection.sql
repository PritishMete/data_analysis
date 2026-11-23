-- Prepare atomic, per-account brute-force protection for Supabase Auth.
--
-- Supabase's Password Verification Attempt hook is available only on Teams and
-- Enterprise plans. This migration installs the hardened hook function but does
-- NOT activate it. An operator must assign it under Authentication > Hooks
-- after the project is on a plan that supports the hook.
--
-- Supabase Auth remains responsible for password verification and bcrypt hashes.
-- The hook receives only user_id and a boolean result; no passwords or IPs are
-- stored here. Supabase's native Auth rate limits remain the IP-level control.

BEGIN;

CREATE TABLE IF NOT EXISTS public.password_failed_verification_attempts (
    user_id UUID PRIMARY KEY
        REFERENCES auth.users (id) ON DELETE CASCADE,
    failure_count INTEGER NOT NULL DEFAULT 0
        CHECK (failure_count > 0),
    window_started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_failed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    blocked_until TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.password_failed_verification_attempts
    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS password_failed_attempts_auth_admin_only
    ON public.password_failed_verification_attempts;

CREATE POLICY password_failed_attempts_auth_admin_only
    ON public.password_failed_verification_attempts
    FOR ALL
    TO supabase_auth_admin
    USING (true)
    WITH CHECK (true);

REVOKE ALL ON TABLE public.password_failed_verification_attempts
    FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE public.password_failed_verification_attempts
    TO supabase_auth_admin;

CREATE OR REPLACE FUNCTION public.insightflow_password_verification_attempt(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_user_id UUID;
    v_valid BOOLEAN;
    v_now TIMESTAMPTZ := pg_catalog.clock_timestamp();
    v_failure_count INTEGER;
    v_blocked_until TIMESTAMPTZ;
BEGIN
    IF pg_catalog.jsonb_typeof(event) IS DISTINCT FROM 'object' THEN
        RETURN pg_catalog.jsonb_build_object(
            'error',
            pg_catalog.jsonb_build_object(
                'http_code', 400,
                'message', 'Invalid password verification event.'
            )
        );
    END IF;

    v_user_id := NULLIF(event ->> 'user_id', '')::UUID;
    v_valid := NULLIF(event ->> 'valid', '')::BOOLEAN;

    IF v_user_id IS NULL OR v_valid IS NULL THEN
        RETURN pg_catalog.jsonb_build_object(
            'error',
            pg_catalog.jsonb_build_object(
                'http_code', 400,
                'message', 'Invalid password verification event.'
            )
        );
    END IF;

    -- A correct password must never be blocked by stale failed-attempt state.
    -- Clear the counter only after Supabase Auth has verified the password.
    IF v_valid THEN
        DELETE FROM public.password_failed_verification_attempts
        WHERE user_id = v_user_id;

        RETURN pg_catalog.jsonb_build_object('decision', 'continue');
    END IF;

    -- This single INSERT .. ON CONFLICT DO UPDATE is atomic under concurrency.
    -- PostgreSQL serializes conflicting updates to the same user_id row, so
    -- simultaneous bad-password requests cannot lose increments.
    --
    -- Escalation within a rolling 15-minute window:
    --   5 failures  -> 1 minute cooldown
    --   8 failures  -> 5 minute cooldown
    --  12 failures  -> 15 minute cooldown
    INSERT INTO public.password_failed_verification_attempts AS attempts (
        user_id,
        failure_count,
        window_started_at,
        last_failed_at,
        blocked_until,
        updated_at
    )
    VALUES (
        v_user_id,
        1,
        v_now,
        v_now,
        NULL,
        v_now
    )
    ON CONFLICT (user_id) DO UPDATE
    SET
        failure_count = CASE
            WHEN attempts.window_started_at <= v_now - INTERVAL '15 minutes'
                THEN 1
            ELSE attempts.failure_count + 1
        END,
        window_started_at = CASE
            WHEN attempts.window_started_at <= v_now - INTERVAL '15 minutes'
                THEN v_now
            ELSE attempts.window_started_at
        END,
        last_failed_at = v_now,
        blocked_until = CASE
            WHEN (
                CASE
                    WHEN attempts.window_started_at <= v_now - INTERVAL '15 minutes'
                        THEN 1
                    ELSE attempts.failure_count + 1
                END
            ) >= 12
                THEN v_now + INTERVAL '15 minutes'
            WHEN (
                CASE
                    WHEN attempts.window_started_at <= v_now - INTERVAL '15 minutes'
                        THEN 1
                    ELSE attempts.failure_count + 1
                END
            ) >= 8
                THEN v_now + INTERVAL '5 minutes'
            WHEN (
                CASE
                    WHEN attempts.window_started_at <= v_now - INTERVAL '15 minutes'
                        THEN 1
                    ELSE attempts.failure_count + 1
                END
            ) >= 5
                THEN v_now + INTERVAL '1 minute'
            ELSE NULL
        END,
        updated_at = v_now
    RETURNING failure_count, blocked_until
    INTO v_failure_count, v_blocked_until;

    IF v_blocked_until IS NOT NULL AND v_blocked_until > v_now THEN
        RETURN pg_catalog.jsonb_build_object(
            'error',
            pg_catalog.jsonb_build_object(
                'http_code', 429,
                'message', 'Sign-in is temporarily restricted after repeated unsuccessful attempts. Try again later.'
            )
        );
    END IF;

    RETURN pg_catalog.jsonb_build_object('decision', 'continue');
END;
$function$;

REVOKE ALL ON FUNCTION public.insightflow_password_verification_attempt(JSONB)
    FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.insightflow_password_verification_attempt(JSONB)
    TO supabase_auth_admin;

COMMIT;
