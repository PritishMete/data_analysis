# InsightFlow Engineering and AI Rules

1. Inspect actual source, tests, configuration, and recent history before changing behavior.
2. Preserve existing working functionality; choose the smallest appropriate change.
3. Do not present placeholders, stubs, skipped checks, or recommendations as complete implementation.
4. Do not invent routes, environment variables, architecture, product behavior, or deployment state.
5. Never hardcode credentials, tokens, private keys, or production connection strings.
6. Never bypass authentication, authorization, workspace isolation, RLS, or validation.
7. Never execute arbitrary AI-generated code against user data.
8. Never directly modify production databases; use reviewed migrations and the repository runner.
9. Do not make unauthorized infrastructure, paid-service, secret, or deployment changes.
10. Do not force-push or push directly to protected `main` without explicit approval.
11. Add or update regression tests for behavior changes and run the relevant CI commands.
12. Disclose failures, skipped tests, uncertainty, and known limitations.
13. Update the relevant documentation after meaningful architecture, security, deployment, or product changes.
14. Treat client-provided roles, scopes, identifiers, and policy decisions as untrusted.
15. Keep diagnostics free of tokens, credentials, raw workbook values, response bodies, and arbitrary paths.
