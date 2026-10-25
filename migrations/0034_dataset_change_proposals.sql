-- Durable, private proposal records for the original-dataset review workflow.
-- Candidate versions remain status='processing' until the approval transaction publishes them.
INSERT INTO permissions(permission_id) VALUES ('dataset.propose')
ON CONFLICT (permission_id) DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
VALUES ('manager', 'dataset.propose')
ON CONFLICT (role_id, permission_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS dataset_change_proposals (
    proposal_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
    dataset_id TEXT NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
    location_id TEXT NOT NULL REFERENCES locations(location_id),
    candidate_version_pk TEXT NOT NULL REFERENCES dataset_versions(version_pk) ON DELETE RESTRICT,
    candidate_version_id TEXT NOT NULL,
    submitted_by_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    base_version_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'stale')),
    original_filename TEXT NOT NULL CHECK (char_length(original_filename) BETWEEN 1 AND 255),
    file_size BIGINT NOT NULL CHECK (file_size >= 0),
    file_hash TEXT NOT NULL CHECK (file_hash ~ '^[0-9a-f]{64}$'),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_by_principal_id TEXT REFERENCES principals(principal_id),
    reviewed_at TIMESTAMPTZ,
    decision_note TEXT CHECK (decision_note IS NULL OR char_length(decision_note) <= 1000),
    CONSTRAINT uq_dataset_change_proposal_candidate UNIQUE (candidate_version_pk)
);

CREATE INDEX IF NOT EXISTS ix_dataset_change_proposals_submitter
    ON dataset_change_proposals (organization_id, workspace_id, submitted_by_principal_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS ix_dataset_change_proposals_branch_status
    ON dataset_change_proposals (organization_id, workspace_id, location_id, status, submitted_at DESC);

-- Supabase API roles receive no table policy. Backend access is through the
-- authenticated server and its database connection; client-side table access is denied.
ALTER TABLE dataset_change_proposals ENABLE ROW LEVEL SECURITY;
