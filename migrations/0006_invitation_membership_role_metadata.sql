ALTER TABLE invitations ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS created_by_principal_id TEXT REFERENCES principals(principal_id);
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS accepted_by_principal_id TEXT REFERENCES principals(principal_id);
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS accepted_at TIMESTAMPTZ;
ALTER TABLE roles ADD COLUMN IF NOT EXISTS system BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE roles SET system=TRUE
WHERE role_id IN ('organization_owner','manager','team_lead','employee','external_viewer');

CREATE INDEX IF NOT EXISTS idx_invitations_org_status ON invitations(organization_id, status);
CREATE INDEX IF NOT EXISTS idx_invitations_email_status ON invitations(lower(email), status);

ALTER TABLE invitations ADD COLUMN IF NOT EXISTS auth_user_id TEXT;
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS email_delivery_status TEXT NOT NULL DEFAULT 'not_started';
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS email_delivery_started_at TIMESTAMPTZ;
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS password_setup_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_invitations_auth_user_id ON invitations(auth_user_id);
