-- Bind invitations to the organizational branch selected by the inviter.
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS location_id TEXT;

ALTER TABLE invitations
    ADD CONSTRAINT fk_invitations_location_same_org
    FOREIGN KEY (organization_id, location_id)
    REFERENCES locations (organization_id, location_id)
    DEFERRABLE INITIALLY IMMEDIATE;

CREATE INDEX IF NOT EXISTS idx_invitations_org_location_status
    ON invitations (organization_id, location_id, status);
