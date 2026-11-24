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

## Task-to-test reference

| Task | Commands / paths | Required workflow or verification |
|---|---|---|
| Backend change | `python -m pytest -q`; focused `tests/test_*.py` | `insightflow-backend-ci.yml`; inspect authz/privacy impact |
| Frontend change | `Push-Location apps/flutter_app; flutter test; flutter analyze; Pop-Location` | `insightflow-backend-ci.yml`; relevant Flutter contract workflow |
| Authentication | Focused auth tests under `apps/flutter_app/test/`, `tests/test_firebase_authz*.py` | `insightflow-backend-ci.yml`, `flutter-web-pages.yml`; verify provider config separately |
| Authorization | `tests/test_authz*.py`, `tests/test_*authorization*.py`, Firebase emulator tests | `insightflow-backend-ci.yml`, `postgres-dataset-security.yml`; verify RLS/grants |
| Database migration | `python -m py_compile tools/run_authz_migrations.py`; disposable PostgreSQL tests | `production-authz-migrations.yml`, PostgreSQL workflows; never use production DB locally |
| Excel integration | `node apps/flutter_app/test/excel_auth_bridge_test.js`; handoff PostgreSQL tests | `excel-auth-postgres-integration.yml`, Flutter Pages workflow; verify Office host behavior |
| AI analysis engine | Focused agent/query/schema/cleaning tests in `tests/` and `apps/flutter_app/test/` | Backend CI plus privacy guard tests; inspect outbound payload boundaries |
| Data privacy | `tests/test_security*.py`, outbound privacy guard tests, security scan | `security-scan.yml` and backend CI; inspect logs and remote payloads |
| Management workspace | Management route tests and Flutter management contract tests | management validation/responsive workflows; verify role-specific journeys |
| UI/responsive change | Focused Flutter widget tests and `flutter analyze` | Flutter CI; test narrow Excel/task-pane dimensions and accessibility states |
| Deployment change | Workflow syntax/config review; provider-specific verification | Relevant GitHub workflow plus Render/Pages dashboard evidence |
| Documentation-only change | `git diff --check`; Markdown/link review; verify only intended docs changed | No application suite required, but report that it was not run |

Environment-dependent suites require Flutter/Dart, Node/npm, Java, Firebase emulator tooling, a disposable PostgreSQL service, or configured provider secrets as stated by the workflow. A skipped or unavailable prerequisite is not a pass.

## Definition of done

- Focused tests pass.
- Relevant regression suite passes.
- Formatting, static analysis, and security checks pass.
- Authz/privacy behavior is covered for changed paths.
- Documentation and migration implications are addressed.
- Any unrun or environment-dependent check is explicitly reported.

## Verification record

This document records available commands and suites; it does not claim they were executed in this documentation task. Actual execution belongs in the final report or `memory.md` decision history.
