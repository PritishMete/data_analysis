-- Add branch scope to protected managed datasets.
-- The application now enforces dataset access by organization + branch.
-- Older production rows predate branch-scoped dataset authorization, so the
-- column is nullable and is conservatively backfilled only when the uploader
-- has exactly one active Branch Head location in the organization.

ALTER TABLE dataset_authorization
    ADD COLUMN IF NOT EXISTS location_id TEXT;

CREATE INDEX IF NOT EXISTS idx_dataset_authorization_org_location_status
    ON dataset_authorization (organization_id, location_id, status);

UPDATE dataset_authorization da
SET location_id = scoped.location_id
FROM (
    SELECT da2.organization_id, da2.dataset_id, MIN(oa.location_id) AS location_id
    FROM dataset_authorization da2
    JOIN organizational_assignments oa
      ON oa.organization_id = da2.organization_id
     AND oa.principal_id = da2.owner_principal_id
     AND oa.role_id = 'branch_head'
     AND oa.status = 'active'
     AND oa.location_id IS NOT NULL
    WHERE da2.location_id IS NULL
    GROUP BY da2.organization_id, da2.dataset_id
    HAVING COUNT(DISTINCT oa.location_id) = 1
) scoped
WHERE da.organization_id = scoped.organization_id
  AND da.dataset_id = scoped.dataset_id
  AND da.location_id IS NULL;

-- Do not guess a branch for ambiguous legacy datasets. Such rows remain
-- organization-owner-visible until an authorized workflow assigns their
-- branch explicitly.
