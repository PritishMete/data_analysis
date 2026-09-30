-- Managed dataset security, per-version schema metadata, and optional private original archive.
-- Analytical rows remain authoritative in PostgreSQL. The Storage bucket is only an optional archive.

CREATE TABLE IF NOT EXISTS dataset_columns (
    id BIGSERIAL PRIMARY KEY,
    dataset_id VARCHAR(36) NOT NULL REFERENCES datasets(dataset_id) ON DELETE CASCADE,
    version_pk VARCHAR(36) REFERENCES dataset_versions(version_pk) ON DELETE CASCADE,
    column_name VARCHAR(255) NOT NULL,
    detected_type VARCHAR(32) NOT NULL,
    nullable BOOLEAN NOT NULL DEFAULT true,
    unique_count INTEGER NOT NULL DEFAULT 0,
    missing_percentage DOUBLE PRECISION NOT NULL DEFAULT 0,
    inferred_role VARCHAR(32),
    inferred_role_confidence DOUBLE PRECISION,
    inferred_role_evidence JSONB,
    role_detected_at TIMESTAMPTZ
);

ALTER TABLE dataset_columns ADD COLUMN IF NOT EXISTS version_pk VARCHAR(36);
CREATE INDEX IF NOT EXISTS ix_dataset_columns_dataset_version
    ON dataset_columns(dataset_id, version_pk);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dataset_columns_version_name
    ON dataset_columns(version_pk, column_name)
    WHERE version_pk IS NOT NULL;

ALTER TABLE datasets ENABLE ROW LEVEL SECURITY;
ALTER TABLE dataset_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE dataset_columns ENABLE ROW LEVEL SECURITY;
ALTER TABLE dataset_rows ENABLE ROW LEVEL SECURITY;

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.insightflow_principal_id()
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT b.principal_id
    FROM public.identity_bindings b
    WHERE b.provider = 'supabase'
      AND b.provider_subject = (SELECT auth.uid()::text)
      AND b.status = 'active'
    LIMIT 1
$$;

REVOKE ALL ON FUNCTION private.insightflow_principal_id() FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.insightflow_principal_id() TO authenticated;

DROP POLICY IF EXISTS managed_datasets_select ON datasets;
CREATE POLICY managed_datasets_select ON datasets
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.organization_members m
        WHERE m.organization_id = datasets.organization_id
          AND m.principal_id = (SELECT private.insightflow_principal_id())
          AND m.status = 'active'
    )
);

DROP POLICY IF EXISTS managed_dataset_versions_select ON dataset_versions;
CREATE POLICY managed_dataset_versions_select ON dataset_versions
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.datasets d
        JOIN public.organization_members m
          ON m.organization_id = d.organization_id
        WHERE d.dataset_id = dataset_versions.dataset_id
          AND m.principal_id = (SELECT private.insightflow_principal_id())
          AND m.status = 'active'
    )
);

DROP POLICY IF EXISTS managed_dataset_columns_select ON dataset_columns;
CREATE POLICY managed_dataset_columns_select ON dataset_columns
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.datasets d
        JOIN public.organization_members m
          ON m.organization_id = d.organization_id
        WHERE d.dataset_id = dataset_columns.dataset_id
          AND m.principal_id = (SELECT private.insightflow_principal_id())
          AND m.status = 'active'
    )
);

DROP POLICY IF EXISTS managed_dataset_rows_select ON dataset_rows;
CREATE POLICY managed_dataset_rows_select ON dataset_rows
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.dataset_versions v
        JOIN public.datasets d ON d.dataset_id = v.dataset_id
        JOIN public.organization_members m ON m.organization_id = d.organization_id
        WHERE v.version_pk = dataset_rows.version_pk
          AND m.principal_id = (SELECT private.insightflow_principal_id())
          AND m.status = 'active'
    )
);

-- Backend uses its server-side PostgreSQL connection for writes. Do not grant
-- direct write access to anon/authenticated through the Data API.
REVOKE ALL ON TABLE datasets, dataset_versions, dataset_columns, dataset_rows FROM anon, authenticated;
GRANT SELECT ON TABLE datasets, dataset_versions, dataset_columns, dataset_rows TO authenticated;
