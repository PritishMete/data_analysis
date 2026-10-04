-- Repair migration for production databases where migration history reports
-- the invitation metadata migration as applied but auth_user_id is absent.
-- This is intentionally idempotent and changes no authorization behavior.

ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS auth_user_id TEXT;

CREATE INDEX IF NOT EXISTS idx_invitations_auth_user_id
    ON invitations(auth_user_id);
