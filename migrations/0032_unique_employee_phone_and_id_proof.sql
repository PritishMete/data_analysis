-- Enforce global uniqueness for employee phone numbers and identity-proof numbers.
-- Phone numbers are stored in canonical E.164 format.
-- Identity-proof values are compared case-insensitively after removing spaces/hyphens.
-- Existing duplicates cause this migration to fail safely; no personal data is deleted.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM organization_member_profiles
        WHERE phone_e164 IS NOT NULL AND btrim(phone_e164) <> ''
        GROUP BY phone_e164
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Cannot enforce unique employee phones: duplicate phone_e164 values already exist.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM organization_member_profiles
        WHERE id_proof_number IS NOT NULL AND btrim(id_proof_number) <> ''
        GROUP BY upper(regexp_replace(id_proof_number, '[[:space:]-]+', '', 'g'))
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Cannot enforce unique employee ID proofs: duplicate normalized ID proof numbers already exist.';
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_profiles_phone_e164_global
    ON organization_member_profiles (phone_e164)
    WHERE phone_e164 IS NOT NULL AND btrim(phone_e164) <> '';

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_profiles_id_proof_global
    ON organization_member_profiles (
        upper(regexp_replace(id_proof_number, '[[:space:]-]+', '', 'g'))
    )
    WHERE id_proof_number IS NOT NULL AND btrim(id_proof_number) <> '';
