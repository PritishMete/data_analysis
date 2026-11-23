-- Supabase function hardening follow-up.
-- Keep trigger behavior intact while closing unnecessary PostgREST EXECUTE grants
-- and pinning the search_path on the remaining invoker trigger functions.
BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_single_active_branch_assignment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF NEW.status = 'active'
       AND NEW.location_id IS NOT NULL
       AND NEW.role_id <> 'organization_owner' THEN
        -- Serialize concurrent assignment attempts for the same member.
        PERFORM 1
        FROM public.organization_members
        WHERE organization_id = NEW.organization_id
          AND principal_id = NEW.principal_id
        FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM public.organizational_assignments existing
            WHERE existing.organization_id = NEW.organization_id
              AND existing.principal_id = NEW.principal_id
              AND existing.status = 'active'
              AND existing.location_id IS NOT NULL
              AND existing.location_id <> NEW.location_id
              AND existing.role_id <> 'organization_owner'
              AND existing.assignment_id IS DISTINCT FROM NEW.assignment_id
        ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'A person can have active assignments in only one branch.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    normalized_number TEXT;
    lock_key TEXT;
BEGIN
    IF NEW.id_proof_number IS NULL OR pg_catalog.btrim(NEW.id_proof_number) = '' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.id_proof_type IS NOT DISTINCT FROM OLD.id_proof_type
       AND NEW.id_proof_number IS NOT DISTINCT FROM OLD.id_proof_number
       AND NEW.country_code IS NOT DISTINCT FROM OLD.country_code THEN
        RETURN NEW;
    END IF;

    normalized_number := pg_catalog.upper(
        pg_catalog.regexp_replace(NEW.id_proof_number, '[[:space:]-]', '', 'g')
    );
    lock_key := NEW.organization_id || ':' || NEW.country_code || ':' ||
                NEW.id_proof_type || ':' || normalized_number;

    -- Serialize concurrent registrations for the same normalized proof.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(lock_key, 0)
    );

    IF EXISTS (
        SELECT 1
        FROM public.organization_member_profiles p
        WHERE p.organization_id = NEW.organization_id
          AND p.principal_id <> NEW.principal_id
          AND p.country_code = NEW.country_code
          AND p.id_proof_type = NEW.id_proof_type
          AND pg_catalog.upper(
              pg_catalog.regexp_replace(p.id_proof_number, '[[:space:]-]', '', 'g')
          ) = normalized_number
    ) THEN
        RAISE EXCEPTION 'duplicate employee ID proof'
            USING ERRCODE = '23505',
                  CONSTRAINT = 'organization_member_profiles_unique_id_proof';
    END IF;

    RETURN NEW;
END;
$$;

-- These routines are trigger/event-trigger entry points, not public RPC APIs.
-- Revoke the default/public API grants while retaining the Auth service grant
-- already required by the account-deletion trigger's deployment contract.
REVOKE ALL ON FUNCTION public.insightflow_cleanup_deleted_auth_user()
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.insightflow_cleanup_deleted_auth_user()
    TO supabase_auth_admin;

REVOKE ALL ON FUNCTION public.insightflow_cleanup_orphaned_branch_organization()
    FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.rls_auto_enable()
    FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
