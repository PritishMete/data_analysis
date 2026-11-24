# InsightFlow Project Memory

## Current verified state

- Last source audit: 2026-11-24.
- Latest main audited: `0cb47cf0` (`Merge pull request #94 from PritishMete/security/finish-hardening-release-gates`).
- Existing documentation branch audited: `codex/security-hardening-deploy`, based on older history and containing the initial six generic docs.
- This documentation work is on a new branch based on latest `origin/main`.
- Current repository evidence includes Flutter Web, Excel bridges, FastAPI routes, Supabase/Firebase authorization, PostgreSQL migrations, Render configuration, GitHub Pages, and multiple CI/security workflows.

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

## Verification record

No application or deployment tests were run for this documentation-only change. Markdown was inspected for scope; Git diff and repository status are the required next checks before PR submission.

## Decision history

### 2026-11-24 — Created project knowledge system

Created ten repository-grounded Markdown documents on a branch from latest `main`. Preserved the existing documentation branch and did not modify application source, migrations, infrastructure, or deployments.
