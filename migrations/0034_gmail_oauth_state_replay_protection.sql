-- Persistent one-time OAuth state for branch-scoped Gmail connection.
-- Raw OAuth state is never stored; only SHA-256(nonce) is retained.
CREATE TABLE IF NOT EXISTS gmail_oauth_states (
  nonce_hash TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
  location_id TEXT NOT NULL REFERENCES locations(location_id) ON DELETE CASCADE,
  principal_id TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gmail_oauth_states_expiry
  ON gmail_oauth_states (expires_at);
