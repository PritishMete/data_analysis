-- Repair production invitation delivery metadata columns when migration history is incomplete.
ALTER TABLE invitations
    ADD COLUMN IF NOT EXISTS email_delivery_status TEXT NOT NULL DEFAULT 'not_started',
    ADD COLUMN IF NOT EXISTS email_delivery_started_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS password_setup_at TIMESTAMPTZ;
