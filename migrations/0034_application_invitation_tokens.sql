-- Application-managed invitation tokens. Raw tokens are never persisted.
-- This migration is forward-only; do not apply it to production without separate approval.
ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS token_hash TEXT,
    ADD COLUMN IF NOT EXISTS token_created_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS redemption_started_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS invitations_token_hash_unique
    ON invitations(token_hash)
    WHERE token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS invitations_pending_email_expiry
    ON invitations (organization_id, lower(email), status);
