# InsightFlow Deployment

## Production service boundaries

The main website uses this path:

`Cloudflare Pages (Flutter frontend) -> Cloudflare Worker API gateway -> Oracle Cloud VM (FastAPI) -> Supabase`

Cloudflare Pages hosts the public static frontend at `https://insightflow-3e8.pages.dev/`.
The public API origin embedded in the Flutter web build is
`https://insightflow-api.jaiphotoshoot.workers.dev`. The Worker forwards requests
to the Oracle VPC binding; the Oracle VM runs the FastAPI application and uses
Supabase for authentication and PostgreSQL persistence.

## Render backend (excluded from the main website)

`render.yaml` defines a Python web service named `data_analysis`, branch `main`, manual deploy trigger, build command `pip install -r requirements.txt`, start command `uvicorn main:app --host 0.0.0.0 --port $PORT`, and health check `/health`.

The service depends on PostgreSQL/Supabase configuration. Secret values must be supplied through Render, not committed. Named variables include `DATABASE_URL`, `SUPABASE_SECRET_KEY`, `SUPABASE_PROJECT_REF`, authentication/provider modes, privacy mode, and environment mode.

Render remains a legacy/alternate deployment record only. The main website must
not embed or call `https://data-analysis-oajs.onrender.com`.

## Oracle Cloud VM backend

The backend can run on the Ubuntu Oracle VM without an application-code change. Run the same entry point behind an HTTPS reverse proxy:

`uvicorn main:app --host 127.0.0.1 --port 8000`

Use the templates in `deploy/oracle/` for the systemd service and deployment starting point. Keep Supabase as the authentication and database provider. Store production values in the VM environment or a protected secrets file; never commit them.

The Flutter Pages workflow reads the public API origin from the GitHub Actions repository variable `INSIGHTFLOW_BACKEND_URL`. Production builds fail closed if it is missing, and source tests reject the legacy Render origin. Set it to the verified Worker origin only after health, authentication, authorization, CORS, upload, and TLS checks pass.

## GitHub Pages Flutter Web

`.github/workflows/flutter-web-pages.yml` installs Flutter, runs bridge/auth/onboarding tests, analyzes changed auth files, validates required build configuration, builds with `/data_analysis/` base href, stamps the commit and OAuth client metadata, creates `404.html`, publishes `gh-pages`, deploys Pages, and verifies the live index, bundle, and fallback.

## Required release process

1. Work from a reviewed branch and PR.
2. Run relevant focused tests and required GitHub checks.
3. Review migration and secret/configuration impact.
4. Obtain explicit deployment approval.
5. Deploy the verified commit through the configured provider workflow.
6. Verify the deployed commit, Worker `/health`, Oracle logs, auth boundary, CORS, and critical user flow.
7. Record result and rollback target in `memory.md`.

## Migrations

Use versioned files in `migrations/` and the repository migration runner. Review ordering, idempotency, RLS, grants, indexes, and rollback/forward strategy. Never run ad hoc production SQL as a substitute for a reviewed migration.

## Rollback

Redeploy the last independently verified commit through Render, the Oracle VM, or the Pages workflow. Application rollback and database rollback are separate decisions; do not assume reverting code safely reverses schema changes.

## Health and incident handling

Verify `/health`, service status, deployment logs, and expected build identity. On failure, stop rollout, preserve logs without exposing secrets, return to the last verified commit, and document the incident and follow-up.

## Verification boundary

Repository configuration proves intended commands, not that a deployment is live. Live status must be verified from Render/GitHub provider results for the specific commit.
