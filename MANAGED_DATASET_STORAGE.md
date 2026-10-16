# Managed dataset storage

Managed datasets use **Supabase PostgreSQL as the authoritative analytical store**. A CSV selected on the user's PC is parsed into dataset/version/schema/row records; the CSV is not stored as a PostgreSQL binary or as authorization metadata.

## Configuration

INSIGHTFLOW_DATASET_MAX_BYTES defaults to 100 MiB.

Original-file archival is optional and disabled by default:

- INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL=false
- INSIGHTFLOW_DATASET_STORAGE_BUCKET=managed-datasets
- SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required only when archival is enabled.

The service key is backend-only. Flutter uses the existing authenticated API and never receives it.

## Analytical storage

PostgreSQL stores:

- datasets
- dataset_versions
- dataset_columns
- dataset_rows (JSONB row records keyed by version_pk and ordered by row_number)

CSV ingestion is chunked. PostgreSQL production uses COPY-style bulk ingestion; test/local non-PostgreSQL dialects use batched inserts. An organization-scoped active file-hash index prevents concurrent exact duplicate dataset creation.

## Optional original archive

When enabled, the original CSV is stored only in the private Supabase Storage bucket:

organizations/<organization_id>/datasets/<dataset_id>/versions/<version_id>/original.csv

The bucket is private and direct authenticated Storage access is denied. Server-side Storage access is performed only by the trusted backend.

## Authorization

Supabase Auth provides the authenticated identity. The existing Supabase-backed InsightFlow authorization model resolves the organization/workspace membership, role, dataset grants, and working-copy permissions server-side.

Dataset rows and CSV contents are never stored in membership, grant, or audit metadata.

## Download

Download CSV reconstructs the file from PostgreSQL:

dataset_version -> version columns -> ordered JSONB rows -> streamed CSV response

The original archived object is not the primary download mechanism.

## Working copies

Start Working uses the existing managed-dataset working-copy authorization path and passes the managed dataset/version identity into the existing DataScreen flow. Remote Smart Query/Sentiment requests can resolve that identity server-side, so Flutter does not copy the full managed dataset into browser memory. No second analysis application or DataScreen is created.

## Firebase boundary

Firebase authentication compatibility elsewhere in InsightFlow remains outside this feature. Firebase Storage, RTDB dataset storage, Firestore dataset storage, Firebase dataset metadata, Firebase dataset versions, and Firebase dataset downloads are not used by this managed dataset lifecycle.
