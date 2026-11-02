-- Integrity guardrails for managed dataset records and immutable version history.
-- This migration deliberately refuses to guess how to repair pre-existing
-- duplicates or broken references. It fails with a clear diagnostic so data
-- can be reconciled explicitly instead of silently deleting records.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM dataset_versions
        GROUP BY dataset_id, version_number
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Cannot add managed-dataset integrity constraints: duplicate (dataset_id, version_number) records exist.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dataset_columns
        WHERE version_pk IS NOT NULL
        GROUP BY version_pk, column_name
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Cannot add managed-dataset integrity constraints: duplicate column names exist within a dataset version.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM dataset_columns c
        JOIN dataset_versions v ON v.version_pk = c.version_pk
        WHERE c.dataset_id <> v.dataset_id
    ) THEN
        RAISE EXCEPTION
            'Cannot add managed-dataset integrity constraints: a column references a version belonging to another dataset.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM datasets d
        WHERE d.current_version_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM dataset_versions v
              WHERE v.dataset_id = d.dataset_id
                AND v.version_id = d.current_version_id
          )
    ) THEN
        RAISE EXCEPTION
            'Cannot add managed-dataset integrity constraints: a dataset current_version_id points to a missing version.';
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_dataset_version_number'
          AND conrelid = 'dataset_versions'::regclass
    ) THEN
        ALTER TABLE dataset_versions
            ADD CONSTRAINT uq_dataset_version_number
            UNIQUE (dataset_id, version_number);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_dataset_version_dataset_pk'
          AND conrelid = 'dataset_versions'::regclass
    ) THEN
        ALTER TABLE dataset_versions
            ADD CONSTRAINT uq_dataset_version_dataset_pk
            UNIQUE (dataset_id, version_pk);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_dataset_version_number_positive'
          AND conrelid = 'dataset_versions'::regclass
    ) THEN
        ALTER TABLE dataset_versions
            ADD CONSTRAINT ck_dataset_version_number_positive
            CHECK (version_number > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_dataset_version_counts_nonnegative'
          AND conrelid = 'dataset_versions'::regclass
    ) THEN
        ALTER TABLE dataset_versions
            ADD CONSTRAINT ck_dataset_version_counts_nonnegative
            CHECK (row_count >= 0 AND column_count >= 0 AND file_size >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_dataset_counts_nonnegative'
          AND conrelid = 'datasets'::regclass
    ) THEN
        ALTER TABLE datasets
            ADD CONSTRAINT ck_dataset_counts_nonnegative
            CHECK (row_count >= 0 AND column_count >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_dataset_current_version'
          AND conrelid = 'datasets'::regclass
    ) THEN
        ALTER TABLE datasets
            ADD CONSTRAINT fk_dataset_current_version
            FOREIGN KEY (dataset_id, current_version_id)
            REFERENCES dataset_versions (dataset_id, version_id)
            DEFERRABLE INITIALLY DEFERRED;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_dataset_column_version_owner'
          AND conrelid = 'dataset_columns'::regclass
    ) THEN
        ALTER TABLE dataset_columns
            ADD CONSTRAINT fk_dataset_column_version_owner
            FOREIGN KEY (dataset_id, version_pk)
            REFERENCES dataset_versions (dataset_id, version_pk)
            ON DELETE CASCADE;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_dataset_columns_version_name
    ON dataset_columns (version_pk, column_name)
    WHERE version_pk IS NOT NULL;
