-- 0020_add_profile_geo_codes.sql
-- Additive profile migration. The original profile table migration is left immutable.
ALTER TABLE organization_member_profiles
  ADD COLUMN IF NOT EXISTS country_code TEXT,
  ADD COLUMN IF NOT EXISTS state_code TEXT;

ALTER TABLE organization_member_profiles
  DROP CONSTRAINT IF EXISTS organization_member_profiles_country_code_check;

ALTER TABLE organization_member_profiles
  ADD CONSTRAINT organization_member_profiles_country_code_check
  CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$');

CREATE INDEX IF NOT EXISTS idx_member_profiles_org_country_state
  ON organization_member_profiles (organization_id, country_code, state_code);
