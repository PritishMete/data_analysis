# Oracle authorization acceptance report

Date: 2026-11-28  
Branch: `codex/oracle-authorization-acceptance-tests-v2-20261128`  
Required HEAD: `62641340598bca75de90e254c0cac2f2a2abde7c`

## Result

**Blocked before execution.** The isolated environment has no
`AUTHZ_TEST_DATABASE_URL`, no `DATABASE_URL`, no `pg_isready`, and no Docker
runtime. The acceptance suite must use a disposable local PostgreSQL database;
SQLite, Supabase, production, and any other database are explicitly out of
scope. No database was contacted or modified.

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
were not relabeled as acceptance evidence.

## Checks performed

- Verified the worktree HEAD exactly matches the required SHA.
- Verified the target worktree is clean before this report was added.
- Inspected repository instructions and existing authz/PostgreSQL test wiring.
- Confirmed the disposable PostgreSQL prerequisite is absent.

## Required rerun environment

Provide a disposable PostgreSQL 16 service and set
`AUTHZ_TEST_DATABASE_URL` to a local test URL whose database is
`insightflow_authz_test` (the existing repository guard accepts only local
hosts). Then rerun the backend acceptance command from this branch and update
this report with per-row HTTP status, response assertions, and database
isolation evidence.

## Scope and conflicts

Only this backend report is changed. No Flutter, privacy, transport, infra,
Worker, Oracle, Render, Supabase, admin, or application-policy files were
changed. No commit or push is claimed until the user-authorized acceptance
environment is available.
