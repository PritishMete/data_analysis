-- Role hierarchy and explicit managed-dataset copy workflow.
-- Additive migration: existing memberships/assignments remain intact.
INSERT INTO permissions(permission_id) VALUES
('dataset.copy.request'),
('dataset.copy.approve'),
('working_copy.assign'),
('authorization.request.view')
ON CONFLICT (permission_id) DO NOTHING;

ALTER TABLE dataset_authorization ADD COLUMN IF NOT EXISTS location_id TEXT;
DO $
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_dataset_authorization_location'
    ) THEN
        ALTER TABLE dataset_authorization
            ADD CONSTRAINT fk_dataset_authorization_location
            FOREIGN KEY (location_id) REFERENCES locations(location_id);
    END IF;
END $;

-- Recover branch scope for legacy datasets only when the owner has one active branch.
WITH owner_locations AS (
    SELECT da.organization_id, da.dataset_id, min(oa.location_id) AS location_id,
           count(DISTINCT oa.location_id) AS location_count
    FROM dataset_authorization da
    JOIN organizational_assignments oa
      ON oa.organization_id=da.organization_id
     AND oa.principal_id=da.owner_principal_id
     AND oa.role_id='branch_head'
     AND oa.status='active'
     AND oa.location_id IS NOT NULL
    WHERE da.location_id IS NULL
    GROUP BY da.organization_id, da.dataset_id
    HAVING count(DISTINCT oa.location_id)=1
)
UPDATE dataset_authorization da
SET location_id=ol.location_id
FROM owner_locations ol
WHERE da.organization_id=ol.organization_id AND da.dataset_id=ol.dataset_id;

CREATE INDEX IF NOT EXISTS idx_dataset_authorization_location
    ON dataset_authorization(organization_id, location_id);

CREATE TABLE IF NOT EXISTS authorization_requests (
    request_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
    requester_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    dataset_id TEXT NOT NULL,
    location_id TEXT REFERENCES locations(location_id),
    request_type TEXT NOT NULL DEFAULT 'dataset_copy'
        CHECK (request_type IN ('dataset_copy')),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','approved','rejected','cancelled')),
    note TEXT,
    reviewed_by_principal_id TEXT REFERENCES principals(principal_id),
    reviewed_at TIMESTAMPTZ,
    resulting_working_copy_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, dataset_id)
        REFERENCES dataset_authorization(organization_id, dataset_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_authz_requests_org_status
    ON authorization_requests(organization_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_authz_requests_requester
    ON authorization_requests(organization_id, requester_principal_id, status);
CREATE INDEX IF NOT EXISTS idx_authz_requests_dataset
    ON authorization_requests(organization_id, dataset_id, status);

CREATE TABLE IF NOT EXISTS working_copy_assignments (
    working_copy_id TEXT NOT NULL,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
    assigned_by_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, working_copy_id, principal_id),
    FOREIGN KEY (organization_id, working_copy_id)
        REFERENCES working_copy_authorization(organization_id, working_copy_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_working_copy_assignments_principal
    ON working_copy_assignments(organization_id, principal_id, status);

ALTER TABLE authorization_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE working_copy_assignments ENABLE ROW LEVEL SECURITY;

-- Rebuild system-role capabilities to match the intended hierarchy.
DELETE FROM role_permissions
WHERE role_id IN (
    'organization_owner','branch_head','manager','team_lead','employee',
    'external_viewer','data_analyst','senior_data_analyst','business_analyst',
    'data_scientist','data_engineer','ml_engineer','analytics_engineer',
    'bi_developer','data_architect','data_quality_analyst','data_governance_analyst'
);

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'organization_owner', permission_id FROM permissions
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'branch_head', permission_id FROM permissions
WHERE permission_id NOT IN ('account.delete')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'manager', permission_id
FROM permissions
WHERE permission_id IN (
    'data.view','analysis.run','worksheet.create','pivot.create',
    'worksheet.modify','worksheet.delete','operation.undo.own','history.view',
    'organization.view','membership.view','membership.manage','invitation.manage',
    'working_copy.view','working_copy.modify','working_copy.delete',
    'working_copy.assign','dataset.copy.request','authorization.request.view',
    'audit.view','excel.mutate.working_copy'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'team_lead', permission_id
FROM permissions
WHERE permission_id IN (
    'data.view','analysis.run','worksheet.create','pivot.create',
    'worksheet.modify','operation.undo.own','history.view',
    'organization.view','membership.view',
    'working_copy.view','working_copy.modify','working_copy.delete',
    'working_copy.assign','dataset.copy.request','authorization.request.view',
    'excel.mutate.working_copy'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT role_id, permission_id
FROM (VALUES
    ('employee','data.view'),('employee','analysis.run'),
    ('employee','worksheet.create'),('employee','pivot.create'),
    ('employee','worksheet.modify'),('employee','operation.undo.own'),
    ('employee','history.view'),('employee','organization.view'),
    ('employee','working_copy.view'),('employee','working_copy.modify'),
    ('employee','excel.mutate.working_copy'),
    ('data_analyst','data.view'),('data_analyst','analysis.run'),
    ('data_analyst','worksheet.create'),('data_analyst','pivot.create'),
    ('data_analyst','worksheet.modify'),('data_analyst','operation.undo.own'),
    ('data_analyst','history.view'),('data_analyst','organization.view'),
    ('data_analyst','working_copy.view'),('data_analyst','working_copy.modify'),
    ('data_analyst','excel.mutate.working_copy'),
    ('senior_data_analyst','data.view'),('senior_data_analyst','analysis.run'),
    ('senior_data_analyst','worksheet.create'),('senior_data_analyst','pivot.create'),
    ('senior_data_analyst','worksheet.modify'),('senior_data_analyst','operation.undo.own'),
    ('senior_data_analyst','history.view'),('senior_data_analyst','organization.view'),
    ('senior_data_analyst','working_copy.view'),('senior_data_analyst','working_copy.modify'),
    ('senior_data_analyst','excel.mutate.working_copy'),
    ('business_analyst','data.view'),('business_analyst','analysis.run'),
    ('business_analyst','worksheet.create'),('business_analyst','pivot.create'),
    ('business_analyst','worksheet.modify'),('business_analyst','operation.undo.own'),
    ('business_analyst','history.view'),('business_analyst','organization.view'),
    ('business_analyst','working_copy.view'),('business_analyst','working_copy.modify'),
    ('business_analyst','excel.mutate.working_copy'),
    ('data_scientist','data.view'),('data_scientist','analysis.run'),
    ('data_scientist','worksheet.create'),('data_scientist','pivot.create'),
    ('data_scientist','worksheet.modify'),('data_scientist','operation.undo.own'),
    ('data_scientist','history.view'),('data_scientist','organization.view'),
    ('data_scientist','working_copy.view'),('data_scientist','working_copy.modify'),
    ('data_scientist','excel.mutate.working_copy'),
    ('data_engineer','data.view'),('data_engineer','analysis.run'),
    ('data_engineer','worksheet.create'),('data_engineer','pivot.create'),
    ('data_engineer','worksheet.modify'),('data_engineer','operation.undo.own'),
    ('data_engineer','history.view'),('data_engineer','organization.view'),
    ('data_engineer','working_copy.view'),('data_engineer','working_copy.modify'),
    ('data_engineer','excel.mutate.working_copy')
) AS seed(role_id, permission_id)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'external_viewer', permission_id
FROM permissions
WHERE permission_id IN ('data.view','history.view','organization.view')
ON CONFLICT DO NOTHING;
