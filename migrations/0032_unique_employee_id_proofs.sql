-- Prevent duplicate employee identity proofs within an organization.
-- Existing duplicates are not deleted automatically; this trigger blocks new
-- duplicate submissions and changes to a duplicate proof while preserving data.
CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    normalized_number TEXT;
    lock_key TEXT;
BEGIN
    IF NEW.id_proof_number IS NULL OR btrim(NEW.id_proof_number) = '' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.id_proof_type IS NOT DISTINCT FROM OLD.id_proof_type
       AND NEW.id_proof_number IS NOT DISTINCT FROM OLD.id_proof_number
       AND NEW.country_code IS NOT DISTINCT FROM OLD.country_code THEN
        RETURN NEW;
    END IF;

    normalized_number := upper(regexp_replace(NEW.id_proof_number, '[[:space:]-]', '', 'g'));
    lock_key := NEW.organization_id || ':' || NEW.country_code || ':' ||
                NEW.id_proof_type || ':' || normalized_number;

    -- Serialize concurrent registrations for the same normalized proof.
    PERFORM pg_advisory_xact_lock(hashtextextended(lock_key, 0));

    IF EXISTS (
        SELECT 1
        FROM public.organization_member_profiles p
        WHERE p.organization_id = NEW.organization_id
          AND p.principal_id <> NEW.principal_id
          AND p.country_code = NEW.country_code
          AND p.id_proof_type = NEW.id_proof_type
          AND upper(regexp_replace(p.id_proof_number, '[[:space:]-]', '', 'g')) = normalized_number
    ) THEN
        RAISE EXCEPTION 'duplicate employee ID proof'
            USING ERRCODE = '23505',
                  CONSTRAINT = 'organization_member_profiles_unique_id_proof';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_duplicate_employee_id_proof
    ON public.organization_member_profiles;

CREATE TRIGGER trg_reject_duplicate_employee_id_proof
BEFORE INSERT OR UPDATE OF id_proof_type, id_proof_number, country_code
ON public.organization_member_profiles
FOR EACH ROW
EXECUTE FUNCTION public.reject_duplicate_employee_id_proof();

REVOKE ALL ON FUNCTION public.reject_duplicate_employee_id_proof() FROM PUBLIC, anon, authenticated;
