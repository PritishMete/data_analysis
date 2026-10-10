-- Disposable application-level invitation tokens.
-- New invitations must not create a Supabase Auth user before acceptance.
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS token_hash TEXT;
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS token_created_at TIMESTAMPTZ;
ALTER TABLE invitations ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_invitations_token_hash
    ON invitations(token_hash)
    WHERE token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_invitations_email_org_pending
    ON invitations(organization_id, lower(email), status);

-- Existing invitations created by the old Supabase-native invite flow retain
-- auth_user_id for compatibility. New rows deliberately leave it NULL.
