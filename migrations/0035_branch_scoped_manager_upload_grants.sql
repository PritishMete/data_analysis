-- Branch-scoped, revocable Manager upload grants and first-publication proposals.
-- Forward-only migration: historical proposals are preserved and made stale where
-- they cannot satisfy the new grant invariant.

CREATE TABLE IF NOT EXISTS manager_dataset_upload_grants (
    grant_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
    manager_principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
    location_id TEXT NOT NULL,
    granted_by_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_by_principal_id TEXT REFERENCES principals(principal_id),
    revoked_at TIMESTAMPTZ,
    revoke_reason TEXT CHECK (revoke_reason IS NULL OR char_length(revoke_reason) <= 1000),
    CONSTRAINT fk_manager_upload_grant_branch
        FOREIGN KEY (organization_id, location_id)
        REFERENCES locations(organization_id, location_id) ON DELETE RESTRICT,
    CONSTRAINT ck_manager_upload_grant_revocation
        CHECK ((revoked_at IS NULL AND revoked_by_principal_id IS NULL)
            OR (revoked_at IS NOT NULL AND revoked_by_principal_id IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_manager_upload_grants_active_branch
    ON manager_dataset_upload_grants
       (organization_id, workspace_id, location_id, manager_principal_id)
    WHERE revoked_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_manager_upload_grant_active
    ON manager_dataset_upload_grants
       (organization_id, workspace_id, location_id, manager_principal_id)
    WHERE revoked_at IS NULL;

ALTER TABLE manager_dataset_upload_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON manager_dataset_upload_grants FROM PUBLIC, anon, authenticated;

-- Manager role membership is not itself upload authority. The server must find
-- an active grant for the exact manager, workspace, organization, and branch.
DELETE FROM role_permissions
WHERE role_id = 'manager' AND permission_id = 'dataset.propose';

ALTER TABLE dataset_change_proposals
    ALTER COLUMN base_version_id DROP NOT NULL;

ALTER TABLE dataset_change_proposals
    ADD COLUMN IF NOT EXISTS dataset_kind TEXT NOT NULL DEFAULT 'existing'
        CHECK (dataset_kind IN ('existing', 'new')),
    ADD COLUMN IF NOT EXISTS upload_grant_id TEXT
        REFERENCES manager_dataset_upload_grants(grant_id) ON DELETE RESTRICT;

-- Existing pending proposals created before explicit grants cannot be approved
-- under the new security model. Preserve their audit trail but prevent publication.
UPDATE dataset_change_proposals
SET status = 'stale',
    reviewed_at = COALESCE(reviewed_at, now()),
    decision_note = COALESCE(decision_note, 'Re-submission required under branch-scoped upload grants.')
WHERE status = 'pending' AND upload_grant_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_dataset_change_proposals_grant
    ON dataset_change_proposals (upload_grant_id, status);

