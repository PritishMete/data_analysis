# InsightFlow Agent Instructions

## Read first

Read documents in this order:

1. `AGENTS.md`
2. `rules.md`
3. The task-specific document: `architecture.md`, `security.md`, `testing.md`, `deployment.md`, `design.md`, `PRD.md`, `phases.md`, or `memory.md`
4. Relevant source files, tests, workflows, and existing `docs/` documents

Source code is the implementation authority. If documentation conflicts with code, report the discrepancy and verify it; do not silently choose either version.

## Before changing anything

- Confirm the requested scope and affected subsystem.
- Inspect the latest `origin/main` and the current branch diff.
- Identify authentication, authorization, privacy, database, deployment, and regression risks.
- Find existing tests and workflows for the affected path.
- Preserve unrelated local changes and do not commit secrets or generated output.

## Implementation protocol

1. Make the smallest change that satisfies the request.
2. Preserve existing working behavior and public contracts.
3. Keep behavior, refactors, tests, and documentation logically separated.
4. Run focused tests first, then the relevant broader checks.
5. Update documentation when behavior, architecture, deployment, or a decision changes.
6. Report actual results, failures, limitations, and unverified items.

## Security and infrastructure

- Never bypass authentication or authorization.
- Never expose workbook values, credentials, tokens, or sensitive logs.
- Never execute arbitrary AI-generated code against user data.
- Never modify production databases directly.
- Never change production infrastructure or trigger deployment without explicit user approval.
- Do not force-push shared branches or push directly to protected `main` unless explicitly authorized.

## Git and PRs

- Branch from the latest `main` with a focused name.
- Keep commits atomic and descriptive.
- Review staged files before committing.
- Create a PR for review; do not merge without approval.
- Do not claim a PR, CI run, deployment, or health check is successful without verifying it.

## Approval-required actions

Ask before production data changes, schema changes, infrastructure changes, secret changes, paid-service changes, merges, force-pushes, or deployments unless the user explicitly authorized that exact action.

## Final report

State changed files, intentionally untouched files, evidence used, tests actually run, failures, deployment status, commit SHA, PR link, and remaining risks.
