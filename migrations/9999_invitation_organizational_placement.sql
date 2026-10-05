-- Preserve trusted organizational placement on employee invitations.
-- Nullable columns keep historical invitations valid. Acceptance code only
-- creates an assignment when placement is present and authoritative.
ALTER TABLE invitations
  ADD COLUMN IF NOT EXISTS location_id TEXT,
  ADD COLUMN IF NOT EXISTS section_id TEXT;

CREATE INDEX IF NOT EXISTS idx_invitations_org_placement
  ON invitations (organization_id, location_id, section_id);
