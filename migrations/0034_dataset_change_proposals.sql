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
    location_id TEXT NOT NULL,
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
    CONSTRAINT uq_dataset_change_proposal_candidate UNIQUE (candidate_version_pk),
    CONSTRAINT fk_dataset_change_proposal_branch
        FOREIGN KEY (organization_id, location_id)
        REFERENCES locations(organization_id, location_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_dataset_change_proposals_submitter
    ON dataset_change_proposals (organization_id, workspace_id, submitted_by_principal_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS ix_dataset_change_proposals_branch_status
    ON dataset_change_proposals (organization_id, workspace_id, location_id, status, submitted_at DESC);

-- Supabase API roles receive no table policy. Backend access is through the
-- authenticated server and its database connection; client-side table access is denied.
ALTER TABLE dataset_change_proposals ENABLE ROW LEVEL SECURITY;

-- Prevent duplicate pending submissions for the same candidate content and base version.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dataset_change_pending_content
    ON dataset_change_proposals (dataset_id, base_version_id, file_hash)
    WHERE status = 'pending';

-- Keep both staged candidates and all other physical dataset versions outside
-- the Supabase Data API. The backend database owner remains able to query them.
REVOKE ALL ON SCHEMA managed_data FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA managed_data FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA managed_data
    REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;

-- A resource grant for the original dataset must not expose pending proposal
-- versions or their schema through the Supabase Data API.
DROP POLICY IF EXISTS managed_dataset_versions_select ON dataset_versions;
CREATE POLICY managed_dataset_versions_select ON dataset_versions
FOR SELECT TO authenticated
USING (
    status = 'ready'
    AND EXISTS (
        SELECT 1
        FROM public.dataset_authorization da
        JOIN public.resource_grants rg
          ON rg.organization_id = da.organization_id
         AND rg.resource_id = da.dataset_id
        WHERE da.dataset_id = dataset_versions.dataset_id
          AND da.status = 'active'
          AND rg.principal_id = (SELECT private.insightflow_principal_id())
          AND rg.permissions ? 'dataset.view_original'
    )
);

DROP POLICY IF EXISTS managed_dataset_columns_select ON dataset_columns;
CREATE POLICY managed_dataset_columns_select ON dataset_columns
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.dataset_versions v
        WHERE v.version_pk = dataset_columns.version_pk
          AND v.dataset_id = dataset_columns.dataset_id
          AND v.status = 'ready'
    )
    AND EXISTS (
        SELECT 1
        FROM public.dataset_authorization da
        JOIN public.resource_grants rg
          ON rg.organization_id = da.organization_id
         AND rg.resource_id = da.dataset_id
        WHERE da.dataset_id = dataset_columns.dataset_id
          AND da.status = 'active'
          AND rg.principal_id = (SELECT private.insightflow_principal_id())
          AND rg.permissions ? 'dataset.view_original'
    )
);

DROP POLICY IF EXISTS managed_dataset_rows_select ON dataset_rows;
CREATE POLICY managed_dataset_rows_select ON dataset_rows
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.dataset_versions v
        JOIN public.dataset_authorization da
          ON da.dataset_id = v.dataset_id
        JOIN public.resource_grants rg
          ON rg.organization_id = da.organization_id
         AND rg.resource_id = da.dataset_id
        WHERE v.version_pk = dataset_rows.version_pk
          AND v.status = 'ready'
          AND da.status = 'active'
          AND rg.principal_id = (SELECT private.insightflow_principal_id())
          AND rg.permissions ? 'dataset.view_original'
    )
);
