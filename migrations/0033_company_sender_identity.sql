-- Company/branch email identity configuration. The generated InsightFlow identity is
-- a desired organizational identity; Gmail transport remains the authenticated
-- account unless a verified Gmail Send-As alias is explicitly authorized.
ALTER TABLE branch_email_settings
    ADD COLUMN IF NOT EXISTS company_name TEXT,
    ADD COLUMN IF NOT EXISTS company_identifier TEXT,
    ADD COLUMN IF NOT EXISTS company_email TEXT,
    ADD COLUMN IF NOT EXISTS company_domain TEXT,
    ADD COLUMN IF NOT EXISTS email_domain TEXT,
    ADD COLUMN IF NOT EXISTS branch_name TEXT,
    ADD COLUMN IF NOT EXISTS branch_identifier TEXT,
    ADD COLUMN IF NOT EXISTS branch_email TEXT,
    ADD COLUMN IF NOT EXISTS sender_identity TEXT,
    ADD COLUMN IF NOT EXISTS sender_identity_mode TEXT NOT NULL DEFAULT 'display_only';

CREATE INDEX IF NOT EXISTS idx_branch_email_settings_sender_identity
    ON branch_email_settings(sender_identity);
