# Oracle authorization acceptance report

Date: 2026-11-28  
Branch: `codex/oracle-authorization-acceptance-tests-v2-20261128`  
Required HEAD: `df8c0da510c7bcb93d51d92cca16e0a9034c4c95`

## Result

**Runtime authorization remains unverified.** The isolated environment has no
`AUTHZ_TEST_DATABASE_URL`, no `DATABASE_URL`, no `pg_isready`, and no Docker
runtime. The acceptance suite must use a disposable local PostgreSQL database;
SQLite, Supabase, production, and any other database are explicitly out of
scope. No database was contacted or modified. The executable suite added in
this revision remains skipped until that prerequisite is supplied.

The requested branch did not exist locally or on `origin`; it was created as a
new isolated worktree from the exact required HEAD. The pre-existing
`codex/oracle-authorization-acceptance-tests` worktree was not changed.

## Acceptance matrix

| Area | Actual FastAPI middleware/routes | Disposable DB result | Status |
|---|---|---:|---|
| Bearer authentication | Required | unavailable | UNVERIFIED |
| Verified email | Required | unavailable | UNVERIFIED |
| Workspace membership | Required | unavailable | UNVERIFIED |
| Resource ownership | Required | unavailable | UNVERIFIED |
| Resource grants | Required | unavailable | UNVERIFIED |
| Managed datasets | Required | unavailable | UNVERIFIED |
| Diagnostics | Required | unavailable | UNVERIFIED |
| Conversation | Required | unavailable | UNVERIFIED |
| Power BI | Required | unavailable | UNVERIFIED |
| Detail Analysis | Required | unavailable | UNVERIFIED |
| Upload/download | Required | unavailable | UNVERIFIED |
| Cross-workspace denial | Required | unavailable | UNVERIFIED |

No row is reported as passing. Existing unit tests that monkeypatch token
verification or authorization services are not substitutes for this matrix and
were not relabeled as acceptance evidence. The new suite uses the real FastAPI
app, middleware, routes, provider wiring, and service layer; it does not mock
policy decisions.

## Executable suite

`tests/integration/test_oracle_authorization_acceptance.py` is the focused
command. It refuses non-PostgreSQL, non-local, or non-dedicated database URLs
and records observed statuses in
`docs/oracle-authorization-acceptance-evidence.json`. Missing-bearer cases
cover managed upload/download/rows, conversation, Detail Analysis, and Power
BI through the real middleware; diagnostics is checked as a real public route.
Provider-backed verified/invalid/expired-token, membership, ownership,
grant/revocation, and successful managed-resource flows remain unverified while
the disposable database and local Supabase-compatible token fixture are
unavailable.

## Checks performed

- Verified the worktree HEAD exactly matches the required SHA.
- Verified the target worktree is clean before this report was added.
- Inspected repository instructions and existing authz/PostgreSQL test wiring.
- Confirmed the disposable PostgreSQL prerequisite is absent.
- Added the executable real-stack acceptance harness; no runtime result is
  claimed from it in this environment.

## Required rerun environment

Provide a disposable PostgreSQL 16 service and set
`AUTHZ_TEST_DATABASE_URL` to a local test URL whose database is
`insightflow_authz_test` (the existing repository guard accepts only local
hosts). Then rerun the backend acceptance command from this branch and update
this report with per-row HTTP status, response assertions, and database
isolation evidence.

Focused command:

```powershell
$env:AUTHZ_TEST_DATABASE_URL = "postgresql+psycopg://postgres:test-only-password@localhost:5432/insightflow_authz_test"
python -m pytest -q -rs tests/integration/test_oracle_authorization_acceptance.py
```

Provider-backed rows additionally need a local Supabase-compatible JWKS and
`/auth/v1/user` fixture (or the repository's disposable auth service), with
verified and unverified users in two workspaces. Do not point the suite at
`DATABASE_URL`, QA, Supabase production, or any remote host.

## Scope and conflicts

Only backend tests/fixtures/report are changed. No Flutter, privacy, transport, infra,
Worker, Oracle, Render, Supabase, admin, or application-policy files were
changed.
