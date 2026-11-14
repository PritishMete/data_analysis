-- InsightFlow branch identity.
-- Every active branch has a human-supplied identifier that is unique across
-- the system. Existing branches receive their already-unique location_id as
-- a safe legacy identifier before the column becomes mandatory.

ALTER TABLE locations
    ADD COLUMN IF NOT EXISTS branch_identifier TEXT;

UPDATE locations
SET branch_identifier = location_id
WHERE branch_identifier IS NULL;

ALTER TABLE locations
    ALTER COLUMN branch_identifier SET NOT NULL;

ALTER TABLE locations
    ADD CONSTRAINT locations_branch_identifier_format
    CHECK (
        branch_identifier ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'
    );

CREATE UNIQUE INDEX IF NOT EXISTS uq_locations_active_branch_identifier
    ON locations (lower(branch_identifier))
    WHERE status = 'active';
