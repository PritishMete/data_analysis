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
- Render startup fails if `DATABASE_URL` is absent. Local development retains
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

## Automated secret and dependency scanning

The repository security workflow checks the full Git history with Gitleaks
using a full-depth checkout and redacted output. A finding must be triaged by
secret type and commit; any live credential requires manual revocation and
replacement by its owner. CI does not rotate credentials or print secret
values. Dependency scanning runs against the Python dependency manifests and
the Flutter lockfile.

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
