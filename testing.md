# InsightFlow Testing

## Test inventory

- Python unit and regression tests: `tests/` and root `test_*.py`.
- PostgreSQL authorization and dataset integration: `tests/test_authz_assignment_index_postgres.py`, `tests/integration/`, and PostgreSQL workflows.
- Firebase authorization: emulator tests and `tests/test_firebase_authz*.py`.
- Flutter unit/widget/contract tests: `apps/flutter_app/test/`.
- Excel bridge tests: `apps/flutter_app/test/excel_auth_bridge_test.js` and related Dart tests.
- Static/security checks: Ruff, Dart/Flutter analysis, formatting, `security-scan.yml`, and workflow contract checks.

## Commands

```powershell
# Python dependencies and tests
python -m pip install -r requirements-test.txt
python -m pytest -q

# Flutter
Push-Location apps/flutter_app
flutter pub get
flutter test
flutter analyze
Pop-Location

# Firebase rules/emulator suite, when Firebase CLI and Java are available
npm install
npm run test:rules
```

Use workflow-specific commands in `.github/workflows/` when reproducing CI. PostgreSQL tests require a disposable PostgreSQL service and the documented environment variables. Do not point them at production.

## CI requirements

Relevant workflows include `insightflow-backend-ci.yml`, `postgres-dataset-security.yml`, `excel-auth-postgres-integration.yml`, `flutter-web-pages.yml`, management validation/responsive workflows, `security-scan.yml`, and production smoke/migration workflows.

## Definition of done

- Focused tests pass.
- Relevant regression suite passes.
- Formatting, static analysis, and security checks pass.
- Authz/privacy behavior is covered for changed paths.
- Documentation and migration implications are addressed.
- Any unrun or environment-dependent check is explicitly reported.

## Verification record

This document records available commands and suites; it does not claim they were executed in this documentation task. Actual execution belongs in the final report or `memory.md` decision history.
