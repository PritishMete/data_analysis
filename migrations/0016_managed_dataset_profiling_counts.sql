-- Additive profiling metadata for managed dataset columns.
-- The existing dataset/version/row architecture remains unchanged.
ALTER TABLE dataset_columns
    ADD COLUMN IF NOT EXISTS missing_count INTEGER NOT NULL DEFAULT 0;

UPDATE dataset_columns
SET missing_count = ROUND(
    (missing_percentage / 100.0) *
    COALESCE((
        SELECT row_count
        FROM dataset_versions v
        WHERE v.version_pk = dataset_columns.version_pk
    ), 0)
)
WHERE missing_count = 0
  AND missing_percentage > 0;

CREATE INDEX IF NOT EXISTS ix_dataset_columns_version_type
    ON dataset_columns(version_pk, detected_type);
