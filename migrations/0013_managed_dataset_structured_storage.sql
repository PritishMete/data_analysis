-- Structured managed-dataset persistence.
-- The analytical representation is rows in SQL; the original CSV remains an object-storage concern.

CREATE TABLE IF NOT EXISTS datasets (
    dataset_id VARCHAR(36) PRIMARY KEY,
    organization_id VARCHAR(128) NOT NULL,
    dataset_name VARCHAR(255) NOT NULL,
    uploaded_by VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    schema_hash VARCHAR(64) NOT NULL DEFAULT '',
    file_hash VARCHAR(64) NOT NULL DEFAULT '',
    row_count INTEGER NOT NULL DEFAULT 0,
    column_count INTEGER NOT NULL DEFAULT 0,
    source_type VARCHAR(32) NOT NULL DEFAULT 'csv',
    last_accessed TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE datasets ADD COLUMN IF NOT EXISTS status VARCHAR(32) NOT NULL DEFAULT 'ready';
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS original_filename VARCHAR(255);
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS content_type VARCHAR(128);
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS file_size BIGINT;
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS storage_provider VARCHAR(64);
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS storage_object_id VARCHAR(512);
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS current_version_id VARCHAR(64);
ALTER TABLE datasets ADD COLUMN IF NOT EXISTS version_number INTEGER NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS ix_datasets_org_status ON datasets(organization_id, status);
CREATE INDEX IF NOT EXISTS ix_datasets_org_file_hash ON datasets(organization_id, file_hash);

CREATE TABLE IF NOT EXISTS dataset_versions (
    version_pk VARCHAR(36) PRIMARY KEY,
    dataset_id VARCHAR(36) NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
    version_id VARCHAR(64) NOT NULL,
    version_number INTEGER NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'processing',
    file_hash VARCHAR(64) NOT NULL,
    schema_hash VARCHAR(64) NOT NULL DEFAULT '',
    row_count INTEGER NOT NULL DEFAULT 0,
    column_count INTEGER NOT NULL DEFAULT 0,
    original_filename VARCHAR(255) NOT NULL,
    content_type VARCHAR(128),
    file_size BIGINT NOT NULL DEFAULT 0,
    storage_provider VARCHAR(64),
    storage_object_id VARCHAR(512),
    created_by VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    failure_reason VARCHAR(1000),
    CONSTRAINT uq_dataset_version_label UNIQUE(dataset_id, version_id)
);

CREATE INDEX IF NOT EXISTS ix_dataset_versions_dataset_created
    ON dataset_versions(dataset_id, created_at);
CREATE INDEX IF NOT EXISTS ix_dataset_versions_file_hash
    ON dataset_versions(file_hash);

CREATE TABLE IF NOT EXISTS dataset_rows (
    row_id BIGSERIAL PRIMARY KEY,
    version_pk VARCHAR(36) NOT NULL REFERENCES dataset_versions(version_pk) ON DELETE CASCADE,
    row_number INTEGER NOT NULL,
    row_data JSONB NOT NULL,
    CONSTRAINT uq_dataset_row_number UNIQUE(version_pk, row_number)
);

CREATE INDEX IF NOT EXISTS ix_dataset_rows_version_row
    ON dataset_rows(version_pk, row_number);

CREATE INDEX IF NOT EXISTS ix_dataset_rows_row_data_gin
    ON dataset_rows USING GIN (row_data);
