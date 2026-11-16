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
- `/docs`, `/redoc`, and `/openapi.json` are disabled by default in production.
  Set `INSIGHTFLOW_ENABLE_OPENAPI=true` only for an explicitly approved,
  temporary diagnostic window.
- Render startup fails if `DATABASE_URL` is absent. Local development retains
  the existing SQLite fallback; tests can use an explicit SQLite URL.

The gateway still relies on the existing Supabase token verification, email
verification, workspace authorization, resource authorization, and role
checks. No Firebase code or provider configuration is removed by this change.
