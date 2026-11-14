-- Managed dataset physical table storage.
-- Each dataset version owns a real table under managed_data.
-- CSV columns become first-class PostgreSQL columns with detected SQL types.

ALTER TABLE dataset_versions
  ADD COLUMN IF NOT EXISTS data_table_name VARCHAR(255);

CREATE SCHEMA IF NOT EXISTS managed_data;

COMMENT ON COLUMN dataset_versions.data_table_name IS
  'Physical managed_data table containing the typed analytical rows for this version';

-- Backend is the only writer/reader of physical dataset tables.
-- Direct Data API access is intentionally not granted to authenticated users.
