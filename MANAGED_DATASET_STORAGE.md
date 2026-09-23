# Managed dataset storage (development/test)

InsightFlow has two dataset modes: local datasets continue through the existing local Excel workflow; managed organization datasets are explicitly uploaded by authorized organization managers and stored as binary objects in the Firebase Storage test provider.

## Configuration

In addition to the existing Firebase Auth/RTDB configuration, the trusted backend requires `FIREBASE_STORAGE_BUCKET`. The optional `INSIGHTFLOW_DATASET_MAX_BYTES` defaults to 100 MiB. Service-account credentials or Application Default Credentials are backend-only.

## Storage layout

`organizations/<workspace_id>/datasets/<dataset_id>/versions/<version_id>/source`

`organizations/<workspace_id>/datasets/<dataset_id>/working-copies/<working_copy_id>/source`

IDs are validated server-side. Filenames are metadata, never authorization identifiers.

## Authorization and privacy

Firebase Auth authenticates. The existing RTDB `firebase_authz` layer authorizes membership, capabilities, dataset ACLs, delegation, working-copy provenance, and audit metadata. Firebase Storage holds binary files only.

Downloads are backend-controlled streams after `dataset.view_original` authorization; no permanent public URL is returned. Retrieved managed files remain eligible for local Excel/InsightFlow analysis. Workbook rows, cell values, prompts, worksheet data, and analysis results are not written to authorization metadata.

## Emulator

`firebase.json` enables Auth, RTDB, and Storage emulators. Run `firebase emulators:start` for local testing. Configure the usual Firebase emulator environment variables for the backend test process; no production bucket is required.

Storage rules deliberately deny all direct client reads/writes. The trusted backend uses Firebase Admin SDK.
