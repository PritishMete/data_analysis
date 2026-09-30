-- Convert legacy JSONB dataset rows into first-class typed PostgreSQL tables.
-- This is a one-time migration for versions created by the interrupted implementation.

CREATE SCHEMA IF NOT EXISTS managed_data;

DO $$
DECLARE
    v RECORD;
    c RECORD;
    table_name TEXT;
    column_defs TEXT := '';
    column_names TEXT := '';
    select_exprs TEXT := '';
    sql TEXT;
    first_col BOOLEAN;
BEGIN
    FOR v IN
        SELECT dv.version_pk, dv.dataset_id
        FROM public.dataset_versions dv
        WHERE dv.data_table_name IS NULL
          AND EXISTS (
              SELECT 1 FROM public.dataset_rows dr
              WHERE dr.version_pk = dv.version_pk
          )
    LOOP
        table_name := 'dataset_' || replace(v.version_pk, '-', '');

        column_defs := '__row_number BIGINT PRIMARY KEY';
        column_names := '__row_number';
        select_exprs := 'row_number';

        FOR c IN
            SELECT column_name, detected_type
            FROM public.dataset_columns
            WHERE version_pk = v.version_pk
            ORDER BY id
        LOOP
            column_defs := column_defs || ', ' ||
                format('%I %s', c.column_name,
                    CASE c.detected_type
                        WHEN 'integer' THEN 'BIGINT'
                        WHEN 'decimal' THEN 'NUMERIC'
                        WHEN 'boolean' THEN 'BOOLEAN'
                        WHEN 'datetime' THEN 'TIMESTAMPTZ'
                        ELSE 'TEXT'
                    END);

            column_names := column_names || ', ' || format('%I', c.column_name);

            select_exprs := select_exprs || ', ' ||
                CASE c.detected_type
                    WHEN 'integer' THEN
                        format('NULLIF(row_data->>%L, '''')::BIGINT', c.column_name)
                    WHEN 'decimal' THEN
                        format('NULLIF(row_data->>%L, '''')::NUMERIC', c.column_name)
                    WHEN 'boolean' THEN
                        format(
                            'CASE WHEN lower(NULLIF(row_data->>%L, '''')) IN (''true'',''1'',''yes'') THEN true
                                  WHEN lower(NULLIF(row_data->>%L, '''')) IN (''false'',''0'',''no'') THEN false
                                  ELSE NULL END',
                            c.column_name, c.column_name
                        )
                    WHEN 'datetime' THEN
                        format('NULLIF(row_data->>%L, '''')::TIMESTAMPTZ', c.column_name)
                    ELSE
                        format('row_data->>%L', c.column_name)
                END;
        END LOOP;

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS managed_data.%I (%s)',
            table_name,
            column_defs
        );

        EXECUTE format(
            'ALTER TABLE managed_data.%I ENABLE ROW LEVEL SECURITY',
            table_name
        );
        EXECUTE format(
            'REVOKE ALL ON TABLE managed_data.%I FROM anon, authenticated',
            table_name
        );

        EXECUTE format(
            'INSERT INTO managed_data.%I (%s)
             SELECT %s
             FROM public.dataset_rows
             WHERE version_pk = %L
             ORDER BY row_number',
            table_name,
            column_names,
            select_exprs,
            v.version_pk
        );

        EXECUTE format(
            'UPDATE public.dataset_versions
             SET data_table_name = %L
             WHERE version_pk = %L',
            table_name,
            v.version_pk
        );
    END LOOP;
END $$;

-- New code no longer writes JSON row payloads. Keep the registry table for
-- backward compatibility with old migrations, but remove migrated payloads.
DELETE FROM public.dataset_rows
WHERE version_pk IN (
    SELECT version_pk
    FROM public.dataset_versions
    WHERE data_table_name IS NOT NULL
);
