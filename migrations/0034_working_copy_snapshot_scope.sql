-- Keep working-copy authorization scope independent of the source master lifecycle.
-- Existing records are backfilled before runtime code relies on the copied scope.
ALTER TABLE working_copy_authorization
    ADD COLUMN IF NOT EXISTS location_id TEXT;

UPDATE working_copy_authorization wc
SET location_id = da.location_id
FROM dataset_authorization da
WHERE wc.organization_id = da.organization_id
  AND wc.source_dataset_id = da.dataset_id
  AND wc.location_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_working_copy_authorization_scope
    ON working_copy_authorization(organization_id, location_id, status);
