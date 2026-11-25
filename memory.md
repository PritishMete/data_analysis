# InsightFlow Project Memory

## Current verified state

- Last source audit: 2026-11-25.
- Latest implementation audit branch: `codex/fix-auth-regressions` (not deployed).
- Latest main audited: `33cad540` (`Merge pull request #95 from PritishMete/codex/project-knowledge-governance`).
- Last verified source commit: `33cad540` before this focused fix branch.
- Existing documentation branch audited: `codex/security-hardening-deploy`, based on older history and containing the initial six generic docs.
- This documentation work is on a new branch based on latest `origin/main`.
- Current repository evidence includes Flutter Web, Excel bridges, FastAPI routes, Supabase/Firebase authorization, PostgreSQL migrations, Render configuration, GitHub Pages, and multiple CI/security workflows.

## Current status and priorities

- Documentation governance: MERGED on PR #95.
- Authentication regression fixes: IMPLEMENTED — NOT VERIFIED in live production; pending review, CI, and deployment.
- Priority 1: review and verify the focused authentication regression branch.
- Priority 2: keep implementation, automated, end-to-end, and production verification separate.
- Priority 3: record independently verified deployment state after a reviewed release.

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

## Latest CI and deployment status

- Latest verified CI result: not established for this documentation revision.
- Latest independently verified Render status: not established for this documentation revision.
- Latest independently verified GitHub Pages status: not established for this documentation revision.
- Never promote these fields to success without provider evidence for a specific commit.

## Decision history

### 2026-11-25 — Isolated authentication regression fixes

Cleared locally rejected refresh-token sessions, unwound authenticated navigation after successful logout, and cleared stale Excel task-pane sessions before opening a new handoff dialog. Preserved token, origin, expiry, and authorization checks. The changes require review and CI before any deployment.

### 2026-11-24 — Created project knowledge system

Created ten repository-grounded Markdown documents on a branch from latest `main`. Preserved the existing documentation branch and did not modify application source, migrations, infrastructure, or deployments.

### 2026-11-24 — Tightened verification and agent guidance

Added instruction precedence, nested-file discovery, compatibility pointers, feature-level phase status, design-token ownership, current-priority tracking, and explicit unverified CI/deployment fields.

## Maintenance protocol

After meaningful implementation, merge, architecture decision, or deployment, update the relevant current-state section and append one concise dated decision entry. Do not add secrets, credentials, or raw user data.
