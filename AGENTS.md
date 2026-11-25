# InsightFlow Agent Instructions

## Purpose and discovery

This is the central repository entry point for coding agents. It is a convention, not a guarantee that every AI product automatically loads it. Agents must discover it explicitly and follow the applicable files.

Before work, search from the repository root for `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, and tool-specific instruction files. A nested file applies to its directory and descendants.

## Read first

Read documents in this order:

1. `AGENTS.md`
2. `rules.md`
3. The task-specific document: `architecture.md`, `security.md`, `testing.md`, `deployment.md`, `design.md`, `PRD.md`, `phases.md`, or `memory.md`
4. Relevant source files, tests, workflows, and existing `docs/` documents

For meaningful implementation work, `memory.md` is mandatory before source inspection. For read-only questions, read only the minimum relevant set and do not edit files unnecessarily.

## Instruction priority

1. System, platform, and safety instructions.
2. Explicit user request and approval boundaries.
3. Repository and organization instructions.
4. The nearest applicable nested instruction file.
5. `AGENTS.md`, then the detailed project documents.
6. Source code, tests, and provider behavior as implementation evidence.

If instructions conflict, stop and report the conflict. Resolve it using the higher-priority source and actual code evidence; never weaken security, skip required checks, or silently reinterpret scope.

Source code is the implementation authority. If documentation conflicts with code, report the discrepancy and verify it; do not silently choose either version.

## Before changing anything

- Confirm the requested scope and affected subsystem.
- Inspect the latest `origin/main` and the current branch diff.
- Identify authentication, authorization, privacy, database, deployment, and regression risks.
- Find existing tests and workflows for the affected path.
- Check nested instructions before editing a file under a subdirectory.
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
- Even with user approval to merge, do not bypass branch protection, required reviews, required checks, or normal PR controls.

## Git and PRs

- Branch from the latest `main` with a focused name.
- Keep commits atomic and descriptive.
- Review staged files before committing.
- Create a PR for review; do not merge without approval.
- Do not claim a PR, CI run, deployment, or health check is successful without verifying it.

## Compatibility entry points

- Gemini CLI: `GEMINI.md` is the project context entry point and references this file.
- GitHub Copilot: `.github/copilot-instructions.md` is repository-wide context and references this file; applicable path-specific instructions may also apply.
- Claude Code: `CLAUDE.md` is a lightweight project pointer to this instruction system. Read `AGENTS.md` and `memory.md` explicitly because compatibility files are pointers, not duplicated policy.

These files are lightweight pointers, not duplicate policy documents.

## Approval-required actions

Ask before production data changes, schema changes, infrastructure changes, secret changes, paid-service changes, merges, force-pushes, or deployments unless the user explicitly authorized that exact action.

## Final report

State changed files, intentionally untouched files, evidence used, tests actually run, failures, deployment status, commit SHA, PR link, and remaining risks.
