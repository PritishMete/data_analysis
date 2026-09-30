-- Tighten managed-dataset RLS to the existing dataset-grant authorization model.
-- Authentication alone, or organization membership alone, is not sufficient.

DROP POLICY IF EXISTS managed_datasets_select ON datasets;
CREATE POLICY managed_datasets_select ON datasets
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.dataset_authorization da
        JOIN public.resource_grants rg
          ON rg.organization_id = da.organization_id
         AND rg.resource_id = da.dataset_id
        WHERE da.organization_id = datasets.organization_id
          AND da.dataset_id = datasets.dataset_id
          AND da.status = 'active'
          AND rg.principal_id = (SELECT private.insightflow_principal_id())
          AND rg.permissions ? 'dataset.view_original'
    )
);

DROP POLICY IF EXISTS managed_dataset_versions_select ON dataset_versions;
CREATE POLICY managed_dataset_versions_select ON dataset_versions
FOR SELECT TO authenticated
USING (
    EXISTS (
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
          AND da.status = 'active'
          AND rg.principal_id = (SELECT private.insightflow_principal_id())
          AND rg.permissions ? 'dataset.view_original'
    )
);

-- No client-side Storage access is required for managed datasets. Keep the
-- original archive private and backend-only.
DROP POLICY IF EXISTS managed_datasets_archive_no_direct_read ON storage.objects;
CREATE POLICY managed_datasets_archive_no_direct_read
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'managed-datasets' AND false);

DROP POLICY IF EXISTS managed_datasets_archive_no_direct_write ON storage.objects;
CREATE POLICY managed_datasets_archive_no_direct_write
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'managed-datasets' AND false);

DROP POLICY IF EXISTS managed_datasets_archive_no_direct_update ON storage.objects;
CREATE POLICY managed_datasets_archive_no_direct_update
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'managed-datasets' AND false)
WITH CHECK (bucket_id = 'managed-datasets' AND false);

DROP POLICY IF EXISTS managed_datasets_archive_no_direct_delete ON storage.objects;
CREATE POLICY managed_datasets_archive_no_direct_delete
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'managed-datasets' AND false);
