-- Identity uniqueness for organization member profiles.
-- Safe preflight: abort before creating indexes if existing identities conflict.
-- Phone numbers are globally unique. ID proofs are unique globally per normalized
-- document type; separators/case are presentation only.
DO $$
DECLARE duplicate_phone_groups bigint;
DECLARE duplicate_id_groups bigint;
BEGIN
  SELECT count(*) INTO duplicate_phone_groups FROM (
    SELECT phone_e164 FROM organization_member_profiles
    WHERE phone_e164 IS NOT NULL AND btrim(phone_e164) <> ''
    GROUP BY phone_e164 HAVING count(DISTINCT principal_id) > 1
  ) conflicts;
  SELECT count(*) INTO duplicate_id_groups FROM (
    SELECT id_proof_type,
           regexp_replace(upper(id_proof_number), '[^A-Z0-9]', '', 'g') AS normalized_number
    FROM organization_member_profiles
    WHERE id_proof_type IS NOT NULL AND id_proof_number IS NOT NULL
      AND regexp_replace(upper(id_proof_number), '[^A-Z0-9]', '', 'g') <> ''
    GROUP BY id_proof_type,
             regexp_replace(upper(id_proof_number), '[^A-Z0-9]', '', 'g')
    HAVING count(DISTINCT principal_id) > 1
  ) conflicts;
  IF duplicate_phone_groups > 0 OR duplicate_id_groups > 0 THEN
    RAISE EXCEPTION
      'Identity uniqueness migration blocked: % duplicate phone groups and % duplicate ID-proof groups. Run the documented identity-conflict preflight, remediate records with an authorized operator, then retry.',
      duplicate_phone_groups, duplicate_id_groups;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_profiles_phone_e164_global
  ON organization_member_profiles (phone_e164)
  WHERE phone_e164 IS NOT NULL AND btrim(phone_e164) <> '';

CREATE UNIQUE INDEX IF NOT EXISTS uq_member_profiles_id_proof_type_normalized_global
  ON organization_member_profiles (
    id_proof_type,
    (regexp_replace(upper(id_proof_number), '[^A-Z0-9]', '', 'g'))
  )
  WHERE id_proof_type IS NOT NULL AND id_proof_number IS NOT NULL
    AND regexp_replace(upper(id_proof_number), '[^A-Z0-9]', '', 'g') <> '';
