# Oracle authorization acceptance test report

## Scope

This report covers the synthetic FastAPI acceptance matrix added on the
`codex/oracle-authorization-acceptance-tests` branch. It exercises the actual
`FirebaseAuthorizationMiddleware` and its route policies for chat, assistant,
conversation, diagnostics, Power BI, and managed datasets.

The test app is disposable. Supabase token verification and authorization
storage are replaced at the external provider boundary, so no second database
or live Supabase project is touched.

## Matrix

| Boundary | Cases | Result |
| --- | --- | --- |
| Bearer authentication | missing, malformed, invalid bearer | verified |
| Tenant context | missing workspace, missing resource | verified |
| Isolation | workspace mismatch, resource mismatch, cross-workspace dataset | verified |
| File ingress | unauthorized multipart upload | verified |
| Managed datasets | route dataset ID wins over generic resource header | **unverified / expected failure** |
| Surfaces | chat, assistant, conversation, diagnostics, Power BI, managed datasets | verified |

## Unverified

Live Supabase JWT/JWKS verification, PostgreSQL policies/migrations, role and
grant rows, storage/download bodies, and deployed ingress behavior are not
verified by this isolated suite. Run the same matrix against the provisioned
acceptance database and Supabase project before release.

The managed-dataset header-conflict test is a strict expected failure: on this
commit the middleware passes a supplied `X-InsightFlow-Resource-ID` through
before the route dataset ID. This PR records the gap only; it intentionally
does not modify production authorization code.

## Verification run

Focused matrix: `15 passed, 1 xfailed`.

Repository suite: `1028 passed, 69 skipped, 30 failed, 10 errors, 1 xfailed`.
The failures are existing environment/authz cutover interactions (including
requests that now correctly receive `401`) and the errors require the absent
`AUTHZ_TEST_DATABASE_URL`; this isolated test does not create or touch another
database.

## Scope guard

No production authorization code, Flutter/privacy/Pages/Worker/infrastructure/
Supabase/admin code was changed.
