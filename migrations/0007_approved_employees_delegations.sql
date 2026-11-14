ALTER TABLE approved_employees
    ADD COLUMN IF NOT EXISTS workspace_id TEXT,
    ADD COLUMN IF NOT EXISTS principal_id TEXT REFERENCES principals(principal_id),
    ADD COLUMN IF NOT EXISTS approved_by_principal_id TEXT REFERENCES principals(principal_id),
    ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;

ALTER TABLE delegations
    ADD COLUMN IF NOT EXISTS workspace_id TEXT,
    ADD COLUMN IF NOT EXISTS member_principal_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS dataset_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS permissions JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_approved_employees_workspace ON approved_employees(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_delegations_workspace_status ON delegations(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_delegations_team_lead ON delegations(organization_id, team_lead_principal_id, status);

ALTER TABLE approved_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE delegations ENABLE ROW LEVEL SECURITY;
