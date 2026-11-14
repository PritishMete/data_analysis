# Repository Structure

## Source of truth

`main` contains maintained source code, project configuration, tests and documentation. `gh-pages` is a deployment-output branch and must contain only the compiled Flutter Web site.

## Current layout

- `apps/flutter_app/`: the single Flutter application for Android, Windows and Web.
- Repository root Python modules and domain packages: FastAPI backend. The current Render entry point is `main:app`, so the backend remains at the root for now.
- `common/`, `core/`, `datasets/`, `ingestion/`, `memory_engine/`, `plan_cache/`, `query_history/`, `schema_intelligence/`, `secure_excel/`, and `sql_cache/`: backend packages grouped by responsibility.
- `frontend/`: existing browser-facing assets.
- `tests/` and root-level `test_*.py`: Python tests. New tests should be added under `tests/` when practical; legacy root-level tests should be relocated only with import and CI configuration updates.
- `tools/`: developer scripts and utilities.
- `docs/`: architecture, setup, deployment and contributor documentation.
- `.github/workflows/`: CI and publishing automation.

## Flutter development

Open `apps/flutter_app/` directly in Android Studio. Use the same project for Android, Windows and Web targets. Flutter Web publishing builds from this directory and publishes the generated artifact to `gh-pages`.

## Backend development

Run commands from the repository root. The existing deployment configuration expects `requirements.txt` and `main.py` at the root. Do not move these files or backend packages independently; a future backend move must update the Render root directory, dependency installation, Python import paths, tests and all related workflows as one coordinated change.

## Excel integration

The `secure_excel/` directory is the Python backend's secure Excel query subsystem. Do not mistake it for a separately packaged Office add-in. If an Office.js add-in is added as a distinct application, place its manifest, package configuration, task-pane UI and JavaScript/TypeScript source in a dedicated `apps/excel_addin/` directory.

## Git branch policy

- `main`: canonical maintained source.
- `gh-pages`: generated static publication files only.
- `feature/*`, `fix/*`, `chore/*`: short-lived branches for active changes.
- No new `backup/*` branches.
- Merge or explicitly reconcile branch changes before deleting development branches.
