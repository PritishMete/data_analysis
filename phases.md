# InsightFlow Evidence-Based Roadmap

Status vocabulary: `NOT STARTED`, `IN PROGRESS`, `IMPLEMENTED — NOT VERIFIED`, `VERIFIED`, `BLOCKED`, `DEPRECATED`.

## Phase 1 — Core analytics path — IMPLEMENTED — NOT VERIFIED

- Objective: scan data, interpret requests, validate plans, execute bounded operations, and return results.
- Evidence: `main.py`, `secure_excel/routes.py`, `schema_intelligence/`, `query_routes/`, `ai_engine.py`, Flutter analysis services and tests.
- Completed: analysis, cleaning, transformation, report, conversation, and schema route families exist.
- Pending: maintain complete contract coverage and verify every supported route in a production-like environment.
- Blockers: no single end-to-end acceptance command covers every route.
- Dependencies: Flutter client, backend runtime, optional database and provider configuration.
- Acceptance: representative workbook requests produce validated results without arbitrary code execution.
- Verification: focused Python tests, Flutter contract tests, privacy/security tests, and manual Excel flow.
- Rollback: revert the focused feature commit; preserve data migrations separately.

Feature status: analysis and transformation routes are implemented; broad end-to-end workbook verification is not established. Detail-analysis and AI workspaces have focused Flutter contracts but are not production-verified.

## Phase 2 — Identity and authorization — IMPLEMENTED — NOT VERIFIED

- Objective: authenticate users and enforce organization, workspace, role, dataset, and resource access.
- Evidence: `firebase_authz/`, `firebase_authz/routes.py`, `firebase_authz/management_routes.py`, migrations, authorization CI workflows.
- Completed in source: profiles, memberships, invitations, roles, assignments, grants, audit routes, and migration verification.
- Pending: continue coverage as new resources are added.
- Blockers: provider behavior depends on configured Firebase/Supabase environments.
- Dependencies: Supabase/PostgreSQL and provider credentials supplied through deployment configuration.
- Acceptance: unauthorized access fails closed and authorized scoped access succeeds.
- Automated verification: `insightflow-backend-ci.yml`, `postgres-dataset-security.yml`, authz tests, and emulator tests exist and cover important paths. This does not establish complete end-to-end or production verification.
- Verification date: source audit 2026-11-24; no fresh execution was performed in this documentation task.
- Rollback: revert application changes; use reviewed forward migrations for schema changes.

## Phase 3 — Excel integration — IMPLEMENTED — NOT VERIFIED

- Objective: connect Excel workbook context and authentication handoff safely.
- Evidence: `apps/flutter_app/lib/core/interop/`, `excel_auth_handoff/`, `secure_excel/`, `EXCEL_AUTHENTICATION.md`.
- Completed: scan/context routes, bridge files, handoff create/complete/claim/cancel flow, bridge tests.
- Pending: verify all supported Office hosts and cancellation/retry paths.
- Blockers: Office host and provider configuration are external dependencies.
- Dependencies: Office.js, Flutter Web, backend URL, auth provider configuration.
- Acceptance: workbook context is handled without leaking raw values; handoff is single-use and expires safely.
- Verification: Excel bridge, PostgreSQL handoff, Flutter auth, and browser checks.
- Rollback: revert bridge/backend changes and disable the affected entry point.

## Phase 4 — Managed datasets and management workspace — IMPLEMENTED — NOT VERIFIED

- Objective: provide authorized dataset lifecycle and management operations.
- Evidence: `dataset_storage/`, `firebase_authz/management_routes.py`, Flutter management features, migrations.
- Completed: dataset registration, versions, proposals, working copies, grants, locations, assignments, and audit surfaces exist.
- Pending: verify complete user journeys across roles and empty/error states.
- Blockers: requires representative authorized database fixtures.
- Dependencies: PostgreSQL/Supabase, identity provider, Flutter management UI.
- Acceptance: each role sees only permitted data and mutations.
- Verification: dataset security, management validation, authorization, and UI contract workflows.
- Rollback: revert application code; use migration rollback/forward strategy approved by the owner.

## Phase 5 — Production operations — IN PROGRESS

- Objective: keep CI, health checks, deployment, security, and rollback reliable.
- Evidence: `.github/workflows/`, `render.yaml`, `RELEASE_PROCESS.md`, `PRIVACY_DEPLOYMENT.md`.
- Completed: backend CI, PostgreSQL checks, Flutter build checks, Render health path, and GitHub Pages verification workflows exist.
- Pending: unify release evidence and keep deployment docs synchronized with current branch policy.
- Blockers: external secrets, provider availability, and deployment approvals.
- Dependencies: GitHub Actions, Render, GitHub Pages, Supabase/PostgreSQL.
- Acceptance: required checks pass; deployed commit and `/health` are independently verified.
- Verification: run the exact workflow and inspect provider dashboards/logs.
- Rollback: redeploy the last verified commit; do not rewrite production data.

Feature status: CI workflows and deployment configuration are implemented; current live Render, Pages, secrets, and production database state are not independently verified in this task.

## Phase 6 — Future product expansion — NOT STARTED

- Objective: expand analytics and modeling capabilities beyond the currently verified contracts.
- Pending: define each feature with a source-backed spec, tests, security review, and rollback plan.
- Acceptance: no feature is marked complete until implementation and verification evidence exist.

## Feature status ledger

| Capability | Source implementation | Automated verification | End-to-end verification | Production verification |
|---|---|---|---|---|
| Core analysis/cleaning | IMPLEMENTED | IMPLEMENTED — NOT VERIFIED | NOT STARTED | NOT STARTED |
| Identity/authz | IMPLEMENTED | IMPLEMENTED — NOT VERIFIED | IMPLEMENTED — NOT VERIFIED | NOT VERIFIED |
| Excel scan/handoff | IMPLEMENTED | IMPLEMENTED — NOT VERIFIED | IMPLEMENTED — NOT VERIFIED | NOT VERIFIED |
| Managed datasets | IMPLEMENTED | IMPLEMENTED — NOT VERIFIED | NOT STARTED | NOT STARTED |
| Flutter Web publication | IMPLEMENTED | IMPLEMENTED — NOT VERIFIED | NOT VERIFIED | NOT VERIFIED |
