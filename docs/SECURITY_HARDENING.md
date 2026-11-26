# Production gateway security hardening

The FastAPI service is the public gateway. The browser sends a Supabase bearer
token to approved API routes; PostgreSQL, Supabase administrative credentials,
and external provider keys remain server-side.

## Controls

- `RequestSizeLimitMiddleware` rejects oversized `Content-Length` and chunked
  bodies before FastAPI parses JSON or multipart data. The default is 100 MiB;
  `INSIGHTFLOW_MAX_REQUEST_BYTES` may lower or raise it up to 500 MiB.
- `DatabaseRateLimiter` stores fixed-window counters in PostgreSQL so limits
  are shared across service instances. It is initialized only after the normal
  production database startup checks succeed.
- Production CORS allows the verified GitHub Pages origin and does not allow
  localhost or browser credentials. Development origins are configured through
  `INSIGHTFLOW_CORS_ORIGINS`.
- API responses receive security headers. JSON/text API responses also receive
  a non-executable CSP; the Flutter HTML deployment is hosted separately and
  is not given an API CSP that could break Office.js or Flutter assets.
- The legacy dataset report renderer escapes untrusted report values, and the
  browser copies only allowlisted HTML/SVG elements and validated presentation
  attributes from an inert DOMParser document into the live DOM. Raw report
  markup is never assigned directly to the output element.
- `/docs`, `/redoc`, and `/openapi.json` are disabled by default in production.
  Set `INSIGHTFLOW_ENABLE_OPENAPI=true` only for an explicitly approved,
  temporary diagnostic window.
- Application startup never executes migrations. Use `tools/run_authz_migrations.py`
  as a separate operator action; production application requires
  `--confirm-production`. Render startup fails if `DATABASE_URL` is absent. Local development retains
  the existing SQLite fallback; tests can use an explicit SQLite URL.

The gateway still relies on the existing Supabase token verification, email
verification, workspace authorization, resource authorization, and role
checks. No Firebase code or provider configuration is removed by this change.

## Transport security and session model

- HSTS is not emitted by default. The Render service terminates TLS upstream of
  the ASGI process, so the application cannot infer the public transport scheme
  from the ASGI scope. Set `INSIGHTFLOW_HSTS_ENABLED=true` only after an
  operator confirms the production hostname and every covered subdomain are
  HTTPS-only and HTTP requests are redirected to HTTPS. The flag is restricted
  to `INSIGHTFLOW_ENV=production`. Do not enable it for preview or local hosts.
- The Flutter Web client uses Supabase's browser-persisted PKCE session and
  sends access tokens as bearer authorization headers. This is not a
  cookie-authenticated API model, so browser CSRF is not the primary threat;
  token theft through XSS or compromised browser storage remains relevant.
  The current browser persistence is not equivalent to Secure, HttpOnly cookie
  storage.
- A secure HttpOnly-cookie migration requires a backend-for-frontend session
  endpoint, server-side refresh-token custody and rotation, cookie issuance and
  revocation, origin/CSRF token validation, and coordinated changes to Flutter
  Web and Excel handoff flows. Do not partially move only one token or client
  path to cookies.
- Production API security headers include a restrictive CSP for JSON/text
  responses, frame denial, MIME sniffing protection, referrer policy, and
  cross-origin resource/opener policies. The Flutter HTML app is hosted on
  GitHub Pages and requires its own hosting-level CSP and source-map review.

## Public client configuration versus secrets

The GitHub Pages build injects the Supabase project URL and Supabase
publishable key, plus the legacy Firebase Web API key, into Flutter Web
build-time configuration. These are public client identifiers/keys by design;
they are not Supabase secret/service-role credentials. Client-side exposure
does not grant authorization by itself: Supabase RLS and server-side
authorization remain mandatory. Restrict the Firebase Web key to the required
APIs and approved HTTP referrers in Google Cloud.

The workflows inspected do not inject `DATABASE_URL`,
`SUPABASE_SECRET_KEY`, or `SUPABASE_SERVICE_ROLE_KEY` into Flutter Web.
The production migration workflow consumes `DATABASE_URL` only in its
server-side job. Keep Gemini, Google Maps server keys, database credentials,
and all Supabase secret/service-role keys in trusted backend environments.

## Automated secret and dependency scanning

The repository security workflow checks the full Git history with Gitleaks
using a full-depth checkout and redacted output. A finding must be triaged by
secret type and commit; any live credential requires manual revocation and
replacement by its owner. CI does not rotate credentials or print secret
values. Dependency scanning runs against the Python dependency manifests and
the Flutter lockfile.

## Password authentication and brute-force controls

- The Flutter client calls `SupabaseClient.auth.signInWithPassword` directly. The
  password request goes to the project's Supabase Auth endpoint
  (`/auth/v1/token`), not through the FastAPI gateway.
- FastAPI's `DatabaseRateLimiter` applies to selected application API routes,
  including `/v1/authz`. It does not intercept or rate-limit the direct
  Supabase Auth password endpoint. Do not describe it as the login endpoint's
  rate limiter.
- Supabase Auth remains the password verifier and password-hash store. The
  application does not implement custom password verification or store a
  second password hash. Supabase's managed password hashing configuration
  must be verified through the provider's current project settings; do not
  infer the live algorithm or cost from application code.
- Migration `0040_password_verification_attempt_protection.sql` installs the
  private attempt table and initial hook function. Migration
  `0041_password_verification_rolling_window.sql` upgrades the prepared
  function to track actual failure timestamps over a rolling 15-minute
  interval and serializes per-user success/failure events with a transaction
  advisory lock.
- The policy is 5 failures = 1 minute, 8 = 5 minutes, and 12 = 15 minutes.
  These account-level restrictions are only enforced if Supabase Auth invokes
  the Password Verification Attempt hook. The project organization was last
  verified on the Free plan, where this hook was not available for assignment.
  The SQL function is therefore prepared code, not an active production
  cooldown control. Do not claim account-level cooldown protection is active.
- Supabase Auth's native IP-based limits remain the provider-side control for
  direct password sign-in. The actual dashboard values, CAPTCHA state, and
  endpoint-specific project configuration must be checked in the Supabase
  dashboard; documentation defaults are not production evidence.
- The PostgreSQL hook test requires `AUTHZ_TEST_DATABASE_URL` and fails if it
  is missing. CI provisions a disposable PostgreSQL 16 service and sets that
  variable at job scope. It tests the prepared SQL only; it does not prove that
  Supabase Auth has assigned or activated the hook.

## External verification still required

- Verify the Render custom hostname and HTTPS redirect behavior before setting
  `INSIGHTFLOW_HSTS_ENABLED=true` in the Render service environment.
- Confirm the Supabase Auth email-confirmation and password-reset expiry
  settings in the Supabase dashboard. Repository code can reject invalid and
  expired JWTs but cannot prove dashboard policy values.
- Confirm production RLS, grants, storage policies, and migration state against
  the live Supabase project. CI PostgreSQL tests use disposable databases only.
- Confirm Render rate-limit table permissions and retention/cleanup policy.
  Centralized alerting requires an external monitoring destination and
  credentials configured by an operator.
- No payment, billing, or payment-provider webhook implementation is intended
  in this product scope; verify again when such functionality is introduced.


## Full-history Gitleaks finding disposition

The full-history scan covered 3,466 commits and initially reported 129 matches:

- 127 `gcp-api-key` matches in historical generated Flutter Web `main.dart.js`
  bundles. Sampled revisions contained the same 39-character Firebase Web API
  key alongside Firebase client configuration. This is a public Firebase
  client identifier, not a Supabase service-role key, private key, or server
  credential. It must still be restricted in Google Cloud to the required APIs
  and approved web referrers.
- 2 `curl-auth-header` matches in historical production smoke-test workflow
  revisions. Both were deliberately invalid diagnostic bearer placeholders,
  not production credentials. The current workflow generates its invalid
  token dynamically.

The repository's `.gitleaks.toml` allowlists only these narrowly scoped
patterns: the GCP API-key detector for generated `main.dart.js` bundles and
the curl-auth-header detector for invalid-prefixed values in the production
smoke-test workflow. Other rules and paths remain scanned.

**Manual external action:** inspect the Firebase Web API key in Google Cloud
Console. Confirm API restrictions permit only required Firebase services and
HTTP referrer restrictions include only the intended production web origin(s).
If the key is unrestricted or has broader API access than required, manually
restrict it and rotate it through the Google Cloud/Firebase owner workflow.
No key was rotated or changed by this PR.
