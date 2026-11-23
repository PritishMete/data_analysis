-- Upgrade password verification tracking from a first-failure window to a true
-- rolling 15-minute window. The existing migration 0040 is already applied in
-- production; this additive migration must be applied separately.
--
-- The Supabase Password Verification Attempt hook is not activated by this
-- migration. It remains plan-gated and must be assigned explicitly by an
-- authorized operator when the project supports it.

BEGIN;

ALTER TABLE public.password_failed_verification_attempts
    ADD COLUMN IF NOT EXISTS failure_timestamps TIMESTAMPTZ[]
    NOT NULL DEFAULT ARRAY[]::TIMESTAMPTZ[];

-- Preserve any existing counter conservatively. The hook was not active on the
-- Free plan, so this is normally empty; if rows exist, retain their count as
-- attempts at the last observed failure time.
UPDATE public.password_failed_verification_attempts
SET failure_timestamps = pg_catalog.array_fill(
    last_failed_at,
    ARRAY[LEAST(GREATEST(failure_count, 1), 1000)]
)
WHERE pg_catalog.cardinality(failure_timestamps) = 0
  AND failure_count > 0;

CREATE OR REPLACE FUNCTION public.insightflow_password_verification_attempt(event JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
    v_user_id UUID;
    v_valid BOOLEAN;
    v_now TIMESTAMPTZ := pg_catalog.clock_timestamp();
    v_timestamps TIMESTAMPTZ[];
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

    BEGIN
        v_user_id := NULLIF(event ->> 'user_id', '')::UUID;
        v_valid := NULLIF(event ->> 'valid', '')::BOOLEAN;
    EXCEPTION
        WHEN invalid_text_representation OR invalid_parameter_value THEN
            RETURN pg_catalog.jsonb_build_object(
                'error',
                pg_catalog.jsonb_build_object(
                    'http_code', 400,
                    'message', 'Invalid password verification event.'
                )
            );
    END;

    IF v_user_id IS NULL OR v_valid IS NULL THEN
        RETURN pg_catalog.jsonb_build_object(
            'error',
            pg_catalog.jsonb_build_object(
                'http_code', 400,
                'message', 'Invalid password verification event.'
            )
        );
    END IF;

    -- Serialize success resets and failures for the same account, including
    -- the first insert when no counter row exists yet.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_user_id::TEXT, 0)
    );

    IF v_valid THEN
        DELETE FROM public.password_failed_verification_attempts
        WHERE user_id = v_user_id;

        RETURN pg_catalog.jsonb_build_object('decision', 'continue');
    END IF;

    SELECT failure_timestamps
    INTO v_timestamps
    FROM public.password_failed_verification_attempts
    WHERE user_id = v_user_id
    FOR UPDATE;

    -- Keep only failures strictly newer than the rolling 15-minute cutoff.
    SELECT COALESCE(
        pg_catalog.array_agg(attempted_at ORDER BY attempted_at),
        ARRAY[]::TIMESTAMPTZ[]
    )
    INTO v_timestamps
    FROM pg_catalog.unnest(
        COALESCE(v_timestamps, ARRAY[]::TIMESTAMPTZ[])
    ) AS attempts(attempted_at)
    WHERE attempted_at > v_now - INTERVAL '15 minutes';

    v_timestamps := pg_catalog.array_append(v_timestamps, v_now);
    v_failure_count := pg_catalog.cardinality(v_timestamps);

    v_blocked_until := CASE
        WHEN v_failure_count >= 12 THEN v_now + INTERVAL '15 minutes'
        WHEN v_failure_count >= 8 THEN v_now + INTERVAL '5 minutes'
        WHEN v_failure_count >= 5 THEN v_now + INTERVAL '1 minute'
        ELSE NULL
    END;

    INSERT INTO public.password_failed_verification_attempts AS attempts (
        user_id,
        failure_count,
        window_started_at,
        last_failed_at,
        blocked_until,
        updated_at,
        failure_timestamps
    )
    VALUES (
        v_user_id,
        v_failure_count,
        v_timestamps[1],
        v_now,
        v_blocked_until,
        v_now,
        v_timestamps
    )
    ON CONFLICT (user_id) DO UPDATE
    SET
        failure_count = EXCLUDED.failure_count,
        window_started_at = EXCLUDED.window_started_at,
        last_failed_at = EXCLUDED.last_failed_at,
        blocked_until = EXCLUDED.blocked_until,
        updated_at = EXCLUDED.updated_at,
        failure_timestamps = EXCLUDED.failure_timestamps;

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
