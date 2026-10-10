-- Branch-scoped Gmail sender configuration.
CREATE TABLE IF NOT EXISTS branch_email_settings (
    setting_id TEXT PRIMARY KEY DEFAULT ('bes_' || gen_random_uuid()::text),
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    location_id TEXT NOT NULL REFERENCES locations(location_id) ON DELETE CASCADE,
    sender_name TEXT NOT NULL DEFAULT 'InsightFlow',
    sender_email TEXT,
    gmail_refresh_token_encrypted TEXT,
    gmail_google_subject TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, location_id)
);
CREATE INDEX IF NOT EXISTS idx_branch_email_settings_location
    ON branch_email_settings(organization_id, location_id);
