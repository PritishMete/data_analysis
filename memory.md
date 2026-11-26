# InsightFlow Project Memory

## Current verified state

- Last source audit: 2026-11-25.
- Latest implementation audit branch: `codex/fix-auth-regressions`, merged by PR #96.
- Latest main audited: `501c507a` (PR #98 merge).
- Last verified source commit: `501c507a3dfe6ef801347221f9941ec93a568134`.
- Existing documentation branch audited: `codex/security-hardening-deploy`, based on older history and containing the initial six generic docs.
- This documentation work is on a new branch based on latest `origin/main`.
- Current repository evidence includes Flutter Web, Excel bridges, FastAPI routes, Supabase/Firebase authorization, PostgreSQL migrations, Render configuration, GitHub Pages, and multiple CI/security workflows.

## Current status and priorities

- Documentation governance: MERGED on PR #95.
- Authentication regression fixes: DEPLOYED in PR #98 — live authenticated user journeys still require authorized manual verification.
- Priority 1: complete live website and Excel Desktop acceptance testing.
- Priority 2: keep implementation, automated, end-to-end, and production verification separate.
- Priority 3: investigate the optional Cloudflare Workers build failure without changing its configuration.
- Current focused bug-fix branch: `codex/fix-excel-and-branch-access`; merged through PR #98.

## Important decisions

- Raw workbook values remain local by default.
- AI output is untrusted and must become a validated structured operation.
- Authentication and authorization are separate boundaries.
- Authorization and database protections are server-side and migration-backed.
- Render and Pages deployments require verified CI and explicit approval.

## Completed in this documentation change

- Added `AGENTS.md`, `security.md`, `testing.md`, and `deployment.md`.
- Replaced generic project drafts with source-backed `PRD.md`, `architecture.md`, `rules.md`, `phases.md`, and `design.md`.
- Added evidence paths, status vocabulary, Mermaid architecture flow, deployment boundaries, and known limitations.

## Known discrepancies and unknowns

- The existing documentation branch is not based on current `main`; its claims require reconciliation before merge.
- Provider secrets, live Render state, live Pages state, and production database contents cannot be verified from source alone.
- The repository contains legacy and current route families; route ownership must be checked per task.
- Some capabilities are implemented but lack one end-to-end acceptance command.
- Phase 2 identity/authorization is implemented and covered by important automated checks, but is not marked fully verified because complete end-to-end and production verification are not established.

## Verification record

- Focused authentication regression contract tests passed locally on 2026-11-25.
- Excel JavaScript bridge tests passed locally on 2026-11-25.
- Backend management/authorization and Excel handoff crypto tests passed locally on 2026-11-25; PostgreSQL-dependent tests were skipped where the disposable database prerequisite was unavailable.
- Live Supabase logs showed invalid refresh-token and refresh-token rate-limit events from the Pages origin; no production configuration or database changes were made.
- Live Excel Desktop and authenticated production user journeys remain unverified.
- Production Supabase logs on 2026-11-25 showed concurrent refresh-token calls from the Pages origin, including HTTP 200 rotations interleaved with `over_request_rate_limit` (429) responses. No tokens or credentials were recorded.
- Render request logs contained no matching Branch Data & Access requests in the inspected window; the failure cannot be claimed as a backend authorization decision without a correlated reproduction.

## Latest CI and deployment status

- Latest verified CI result: all required PR #98 checks and post-merge workflows passed for `501c507a3dfe6ef801347221f9941ec93a568134`; the optional Cloudflare Workers check remains failed and unresolved.
- Latest Render status: live deployment `dep-dc36qau8bjmc73epdjs0`, service `data_analysis`, commit `501c507a3dfe6ef801347221f9941ec93a568134`; `/health` returned 200 with `database_ready: true`, `/ping` returned 200, and `/v1/build-info` matched the commit.
- Previous Render rollback target: live deployment `dep-dc35do7avr4c73ecb4ag`, commit `c1798aa5be269c0c9ef2342653c2e449aef72609`.
- GitHub Pages workflow `45551154577` failed at the final artifact deployment step because the provider reported no `github-pages` artifact; a rerun failed the same way. Independently, the live Pages index returned 200 and contained `501c507a3dfe6ef801347221f9941ec93a568134`.
- Live backend build identity: frontend build `447cc1b2d429`; backend commit `501c507a3dfe6ef801347221f9941ec93a568134`.
- Render CORS for `https://pritishmete.github.io` returned 200 on preflight; unauthenticated managed-dataset access returned 401; no Render error logs were observed in the inspected post-deploy window.
- PR #97 remains open and stale, containing a memory-only update based on older main; it was not merged or used to overwrite newer verified deployment information.
- Never promote these fields to success without provider evidence for a specific commit.

## Decision history

### 2026-11-25 — Isolated authentication regression fixes

Cleared locally rejected refresh-token sessions, unwound authenticated navigation after successful logout, and cleared stale Excel task-pane sessions before opening a new handoff dialog. Preserved token, origin, expiry, and authorization checks. The changes require review and CI before any deployment.

### 2026-11-25 — Merged and deployed PR #98

PR #98 merged through the protected process as main commit `501c507a3dfe6ef801347221f9941ec93a568134`. Render deployment `dep-dc36qau8bjmc73epdjs0` is live and matches that commit. Health, database readiness, ping, build identity, CORS, and unauthenticated protection checks passed. GitHub Pages live content matches the merged commit, but workflow `45551154577` failed at its final artifact publication step and remains a provider/workflow issue requiring separate investigation. Excel Desktop and authenticated production acceptance tests remain pending.

### 2026-11-25 — Investigated remaining Excel and Branch access failures

The reported Excel dialog failure is consistent with refresh-token contention: `refreshAuthenticatedUser()` called `refreshSession()` directly while Supabase automatic refresh and task-pane/dialog contexts could rotate the same session concurrently. The focused fix routes authoritative user verification through the shared session coordinator and adds sanitized operation/correlation diagnostics. Branch Data & Access now rebuilds its bearer headers from the coordinated session and re-resolves a missing workspace selector from authoritative `/v1/authz/me` membership data; no permissions or database policy were changed. Live authenticated acceptance remains pending.

### 2026-11-24 — Created project knowledge system

Created ten repository-grounded Markdown documents on a branch from latest `main`. Preserved the existing documentation branch and did not modify application source, migrations, infrastructure, or deployments.

### 2026-11-24 — Tightened verification and agent guidance

Added instruction precedence, nested-file discovery, compatibility pointers, feature-level phase status, design-token ownership, current-priority tracking, and explicit unverified CI/deployment fields.

## Maintenance protocol

After meaningful implementation, merge, architecture decision, or deployment, update the relevant current-state section and append one concise dated decision entry. Do not add secrets, credentials, or raw user data.
