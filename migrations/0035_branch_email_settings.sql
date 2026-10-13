-- Server-only storage for branch-scoped Gmail OAuth and sender configuration.
CREATE TABLE IF NOT EXISTS branch_email_settings (
  organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
  location_id TEXT NOT NULL REFERENCES locations(location_id) ON DELETE CASCADE,
  sender_name TEXT NOT NULL DEFAULT 'InsightFlow',
  sender_email TEXT NOT NULL,
  sender_identity TEXT,
  gmail_refresh_token_encrypted TEXT,
  gmail_google_subject TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,location_id)
);
