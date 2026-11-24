# InsightFlow Deployment

## Render backend

`render.yaml` defines a Python web service named `data_analysis`, branch `main`, manual deploy trigger, build command `pip install -r requirements.txt`, start command `uvicorn main:app --host 0.0.0.0 --port $PORT`, and health check `/health`.

The service depends on PostgreSQL/Supabase configuration. Secret values must be supplied through Render, not committed. Named variables include `DATABASE_URL`, `SUPABASE_SECRET_KEY`, `SUPABASE_PROJECT_REF`, authentication/provider modes, privacy mode, and environment mode.

## GitHub Pages Flutter Web

`.github/workflows/flutter-web-pages.yml` installs Flutter, runs bridge/auth/onboarding tests, analyzes changed auth files, validates required build configuration, builds with `/data_analysis/` base href, stamps the commit and OAuth client metadata, creates `404.html`, publishes `gh-pages`, deploys Pages, and verifies the live index, bundle, and fallback.

## Required release process

1. Work from a reviewed branch and PR.
2. Run relevant focused tests and required GitHub checks.
3. Review migration and secret/configuration impact.
4. Obtain explicit deployment approval.
5. Deploy the verified commit through the configured provider workflow.
6. Verify the deployed commit, `/health`, logs, auth boundary, and critical user flow.
7. Record result and rollback target in `memory.md`.

## Migrations

Use versioned files in `migrations/` and the repository migration runner. Review ordering, idempotency, RLS, grants, indexes, and rollback/forward strategy. Never run ad hoc production SQL as a substitute for a reviewed migration.

## Rollback

Redeploy the last independently verified commit through Render or the Pages workflow. Application rollback and database rollback are separate decisions; do not assume reverting code safely reverses schema changes.

## Health and incident handling

Verify `/health`, service status, deployment logs, and expected build identity. On failure, stop rollout, preserve logs without exposing secrets, return to the last verified commit, and document the incident and follow-up.

## Verification boundary

Repository configuration proves intended commands, not that a deployment is live. Live status must be verified from Render/GitHub provider results for the specific commit.
