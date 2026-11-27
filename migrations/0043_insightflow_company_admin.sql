-- Diagnostic sessions need the branch context used by the claim and ingestion APIs.
ALTER TABLE diagnostic_sessions ADD COLUMN IF NOT EXISTS branch_id TEXT;

-- Company-wide InsightFlow support authorization is separate from tenant roles.
-- No customer organization membership is required for this internal role.
CREATE TABLE IF NOT EXISTS insightflow_company_admins (
    principal_id TEXT PRIMARY KEY REFERENCES principals(principal_id) ON DELETE CASCADE,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    revoked_at TIMESTAMPTZ,
    revoked_by_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    CONSTRAINT company_admin_revocation_state CHECK (
      (active = true AND revoked_at IS NULL) OR (active = false)
    )
);
CREATE TABLE IF NOT EXISTS insightflow_company_admin_audit (
    audit_id TEXT PRIMARY KEY,
    actor_principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    target_principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS insightflow_company_admin_audit_time_idx
  ON insightflow_company_admin_audit(created_at DESC);
ALTER TABLE insightflow_company_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE insightflow_company_admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON insightflow_company_admins, insightflow_company_admin_audit FROM anon, authenticated;
