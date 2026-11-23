-- Store employee phone and government ID proof values as authenticated ciphertext.
-- Per-field salts are random and independent; the duplicate-proof token is a
-- keyed, organization-scoped HMAC so the existing uniqueness rule still works.
BEGIN;

ALTER TABLE organization_member_profiles
    ADD COLUMN IF NOT EXISTS phone_ciphertext BYTEA,
    ADD COLUMN IF NOT EXISTS phone_salt BYTEA,
    ADD COLUMN IF NOT EXISTS phone_hmac BYTEA,
    ADD COLUMN IF NOT EXISTS id_proof_ciphertext BYTEA,
    ADD COLUMN IF NOT EXISTS id_proof_salt BYTEA,
    ADD COLUMN IF NOT EXISTS id_proof_hmac BYTEA,
    ADD COLUMN IF NOT EXISTS id_proof_fingerprint BYTEA;

ALTER TABLE organization_member_profiles
    DROP CONSTRAINT IF EXISTS organization_member_profiles_phone_crypto_complete,
    DROP CONSTRAINT IF EXISTS organization_member_profiles_id_crypto_complete;

ALTER TABLE organization_member_profiles
    ADD CONSTRAINT organization_member_profiles_phone_crypto_complete
    CHECK (
      (phone_ciphertext IS NULL AND phone_salt IS NULL AND phone_hmac IS NULL)
      OR
      (phone_ciphertext IS NOT NULL AND phone_salt IS NOT NULL AND phone_hmac IS NOT NULL)
    ),
    ADD CONSTRAINT organization_member_profiles_id_crypto_complete
    CHECK (
      (id_proof_ciphertext IS NULL AND id_proof_salt IS NULL
       AND id_proof_hmac IS NULL AND id_proof_fingerprint IS NULL)
      OR
      (id_proof_ciphertext IS NOT NULL AND id_proof_salt IS NOT NULL
       AND id_proof_hmac IS NOT NULL AND id_proof_fingerprint IS NOT NULL)
    );

DROP INDEX IF EXISTS idx_member_profiles_org_phone;
CREATE UNIQUE INDEX IF NOT EXISTS uq_member_profiles_org_id_proof_fingerprint
    ON organization_member_profiles
       (organization_id, country_code, id_proof_type, id_proof_fingerprint)
    WHERE id_proof_fingerprint IS NOT NULL;

CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    lock_key TEXT;
BEGIN
    IF NEW.id_proof_fingerprint IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.id_proof_type IS NOT DISTINCT FROM OLD.id_proof_type
       AND NEW.id_proof_fingerprint IS NOT DISTINCT FROM OLD.id_proof_fingerprint
       AND NEW.country_code IS NOT DISTINCT FROM OLD.country_code THEN
        RETURN NEW;
    END IF;

    lock_key := NEW.organization_id || ':' || NEW.country_code || ':' ||
                NEW.id_proof_type || ':' ||
                pg_catalog.encode(NEW.id_proof_fingerprint, 'hex');

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
          AND p.id_proof_fingerprint = NEW.id_proof_fingerprint
    ) THEN
        RAISE EXCEPTION 'duplicate employee ID proof'
            USING ERRCODE = '23505',
                  CONSTRAINT = 'organization_member_profiles_unique_id_proof';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_duplicate_employee_id_proof()
    FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_reject_duplicate_employee_id_proof
    ON public.organization_member_profiles;
CREATE TRIGGER trg_reject_duplicate_employee_id_proof
    BEFORE INSERT OR UPDATE ON public.organization_member_profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.reject_duplicate_employee_id_proof();

COMMIT;
