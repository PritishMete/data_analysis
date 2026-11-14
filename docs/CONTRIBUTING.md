# Contributing to InsightFlow

## Project map

Read [Repository Structure](REPOSITORY_STRUCTURE.md) before changing project paths or deployment configuration.

- Flutter app: `apps/flutter_app/`
- FastAPI backend: repository root, entered through `main.py`
- Python domain packages: `common/`, `datasets/`, `ingestion/`, `memory_engine/`, `schema_intelligence/`, `secure_excel/`, and related packages
- Python tests: `tests/` (some legacy tests remain at the root)
- Developer tools: `tools/`
- CI and deployment workflows: `.github/workflows/`

## Local setup

### Flutter

Open `apps/flutter_app/` in Android Studio, then run:

```bash
flutter pub get
```

### Backend

From the repository root:

```bash
python -m venv .venv
# Activate the virtual environment for your operating system.
pip install -r requirements.txt
python -m uvicorn main:app --reload --host 127.0.0.1 --port 8000
```

## Change guidelines

1. Keep one Flutter project for Android, Windows and Web.
2. Keep backend imports and the current `uvicorn main:app` entry point intact unless a complete backend relocation is planned.
3. Keep generated Flutter Web output out of `main`; the publishing workflow writes it to `gh-pages`.
4. Never commit secrets, local environment files, build caches or generated artifacts.
5. Put new Python tests under `tests/` where practical.
6. Use descriptive feature/fix/chore branches and merge completed work into `main`.
7. Do not create backup branches. Preserve recoverability through normal Git history and reviewed pull requests.
8. When moving files, update every workflow, script, import, IDE path and deployment configuration that references them.
