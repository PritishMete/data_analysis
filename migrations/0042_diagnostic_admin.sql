-- Diagnostic records are intentionally separate from audit_events.
CREATE TABLE IF NOT EXISTS diagnostic_sessions (
    session_id TEXT PRIMARY KEY,
    organization_id TEXT REFERENCES organizations(organization_id) ON DELETE CASCADE,
    user_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    created_by_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    claim_token_hash TEXT,
    claimed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT diagnostic_session_claim_state CHECK ((claimed_at IS NULL AND claim_token_hash IS NOT NULL) OR (claimed_at IS NOT NULL AND claim_token_hash IS NULL))
);
CREATE TABLE IF NOT EXISTS diagnostic_events (
    event_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES diagnostic_sessions(session_id) ON DELETE CASCADE,
    organization_id TEXT REFERENCES organizations(organization_id) ON DELETE CASCADE,
    user_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    branch_id TEXT,
    event_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    correlation_id TEXT NOT NULL,
    category TEXT NOT NULL,
    status TEXT NOT NULL,
    sanitized_error TEXT,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS diagnostic_support_admins (
    principal_id TEXT PRIMARY KEY REFERENCES principals(principal_id) ON DELETE CASCADE,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    branch_id TEXT,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS diagnostic_events_scope_idx ON diagnostic_events(organization_id, user_principal_id, event_at DESC);
CREATE INDEX IF NOT EXISTS diagnostic_events_correlation_idx ON diagnostic_events(correlation_id);
CREATE INDEX IF NOT EXISTS diagnostic_sessions_expiry_idx ON diagnostic_sessions(expires_at);
CREATE INDEX IF NOT EXISTS diagnostic_events_branch_idx ON diagnostic_events(organization_id, branch_id, event_at DESC);
ALTER TABLE diagnostic_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_support_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON diagnostic_sessions, diagnostic_events, diagnostic_support_admins FROM anon, authenticated;
-- Client roles cannot mutate diagnostic history. The backend connection retains
-- ownership so retention cleanup can be implemented as a reviewed job.
REVOKE UPDATE, DELETE ON diagnostic_sessions, diagnostic_events FROM anon, authenticated;
