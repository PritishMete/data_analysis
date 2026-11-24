# InsightFlow Security

## Threat model

Protect workbook values, business identifiers, credentials, sessions, organization boundaries, dataset authorization, and production database integrity from malicious users, compromised clients, prompt-injected AI output, accidental logging, and misconfigured deployments.

## Authentication

Flutter authentication services and backend provider adapters establish and verify identity. Excel authentication uses the short-lived handoff routes in `excel_auth_handoff/routes.py`. Authentication failure must not fall through to anonymous privileged behavior.

## Authorization and isolation

Authorization is server-side and resource-scoped. Organization, workspace, role, dataset, working-copy, grant, and management operations are implemented under `firebase_authz/` and `dataset_storage/`. Database RLS and migration verification are defense-in-depth controls.

## Privacy

The secure Excel path keeps raw workbook content local by default. `apps/flutter_app/lib/core/security/outbound_privacy_guard.dart`, privacy-mode settings, and backend policy controls limit outbound data. Do not log raw workbook values, identifiers, tokens, cookies, credentials, or response bodies.

## Secrets

Use environment variables or the deployment provider’s secret store. Repository configuration may document variable names, never secret values. Relevant names include `DATABASE_URL`, `SUPABASE_SECRET_KEY`, provider keys, and Flutter build defines.

## Validation and AI restrictions

Validate request schemas, identifiers, operators, data types, limits, and authorization before execution. AI output is untrusted: it may propose intent but cannot grant access, choose a user role, or execute arbitrary Python/shell code.

## Database security

Use ordered migrations, transactional application, advisory locking, migration history, RLS, restricted grants, and security integration tests. Do not edit production tables manually.

## Testing and response

Security coverage exists in `tests/`, Firebase emulator workflows, PostgreSQL workflows, `security-scan.yml`, and Flutter privacy/auth tests. For an incident: contain access, preserve relevant non-sensitive evidence, rotate affected secrets, assess scope, restore from a verified deployment, and document follow-up.

## Known risks

- External provider and secret configuration cannot be verified from repository source alone.
- Some route families and legacy paths coexist; every new endpoint needs explicit authz review.
- Advisory AI/schema inference can be misunderstood if UI scope and uncertainty are not shown.
- Dependency warnings and provider deprecations require ongoing maintenance.
