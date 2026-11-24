# InsightFlow Product Requirements

## Status and evidence

This document describes the current repository as audited on 2026-11-24. Implemented means source and tests exist; verified means the relevant check was actually run. See `phases.md` for status.

## Vision

Help Excel users move from workbook data to trustworthy analysis through natural-language requests, constrained operations, and privacy-preserving execution.

## Users and use cases

- Excel-based business users: scan a workbook, ask questions, filter, group, summarize, clean, and export results.
- Analysts: profile multiple sheets, inspect schema roles, identify relationships, and build reports.
- Managers: review authorized datasets, proposals, access requests, and audit activity.
- Administrators: manage organizations, members, roles, locations, assignments, invitations, and dataset grants.

## Functional requirements

- Provide Flutter Web and Excel-hosted experiences with authenticated access where configured.
- Scan workbook context and expose local schema metadata to the analysis flow.
- Interpret requests into structured plans and validate operations before execution.
- Support analysis, cleaning, categorization, range binning, reports, charts, conversation state, and detail analysis where implemented.
- Support managed datasets, versions, working copies, upload grants, proposals, downloads, and dataset authorization.
- Support Excel authentication handoff with create, complete, claim, and cancel operations.
- Enforce organization, workspace, role, dataset, and resource authorization server-side.
- Expose health and build information for deployment verification.

## Non-functional requirements

- Privacy-first local processing by default.
- Fail-closed identity and authorization behavior.
- Versioned, transactional PostgreSQL migrations with verification.
- Repeatable automated tests for Python, PostgreSQL, Firebase authorization, Flutter, Excel bridge, security, and deployment paths.
- Responsive task-pane behavior and accessible UI states.
- Reversible deployment and documented rollback.

## Privacy and security requirements

Raw workbook values, filenames, sheet names, identifiers, tokens, credentials, and response bodies must not be sent to remote AI services or written to logs by default. AI output is untrusted and cannot select permissions or execute arbitrary code.

## Supported platforms

- Flutter Web and GitHub Pages.
- Excel-hosted Office.js integration through the Flutter Web bridge.
- Python/FastAPI service on Render.
- Supabase/PostgreSQL-backed identity, authorization, and persistence.

## Scope and limitations

Implemented capabilities are bounded by the routes and tests in this repository. Relationship detection is advisory. Some integration paths require disposable PostgreSQL or Firebase emulator configuration. Unsupported or unverified behavior must not be presented as complete.

## Acceptance criteria

- A valid user request produces a validated, bounded operation or a safe explanation.
- Unauthorized dataset or management operations are rejected server-side.
- Sensitive data is absent from diagnostics and outbound payloads.
- Relevant CI jobs pass for a change before production deployment.
- `/health` returns successfully after deployment and the deployed commit is independently verified.

## Explicit non-goals

- Arbitrary generated Python execution.
- Silent authorization inference from client claims.
- Treating AI-generated schema relationships as authoritative.
- Direct production database editing as a normal workflow.
