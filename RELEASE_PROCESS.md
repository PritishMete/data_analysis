# InsightFlow release and deployment process

## Canonical production architecture

As verified on 24 November 2026, the production backend is the existing
Render web service `data_analysis`
(`https://data-analysis-oajs.onrender.com`). It deploys from `main`, uses
`uvicorn main:app --host 0.0.0.0 --port $PORT`, checks `/health`. Auto-deploy is disabled.

The Flutter web frontend is built and published to the repository's
`gh-pages` branch by the GitHub Actions workflow
`.github/workflows/flutter-web-pages.yml`. Its configured production URL is
`https://pritishmete.github.io/data_analysis/`. The workflow builds the
Flutter application, validates its auth integration and generated bundle,
publishes the bundle to `gh-pages`, and deploys a GitHub Pages artifact.

The repository source tree and workflow configuration contain no Cloudflare
Worker/Wrangler configuration, Worker entry point, Cloudflare deployment
workflow, or Cloudflare runtime dependency. The owner has explicitly removed
the Cloudflare GitHub integration. Accordingly, Cloudflare Workers and Pages
are not part of the current mandatory production release process. This is not
a claim that the historical Cloudflare check succeeded, nor does it authorize
deleting any separately hosted Cloudflare resource. If Cloudflare services
are reintroduced into the production architecture, their ownership, runtime
routes, deployment source, and health checks must be reviewed before they
become release gates again.

GitHub's existing check runs from before the integration was removed can
remain visible on old PR commits. In particular, the historical
`Workers Builds: insightflow` failure remains a failure in GitHub's record;
it is retired from the current release gate because the owner removed that
integration, not because the failed check was repaired or converted to a
success. A historical Cloudflare Pages success is likewise not a current
mandatory check.

`main` is the canonical production source branch. Do not deploy a feature
branch or assume that changing `render.yaml` updates the existing Render
service. Any change to the production source branch requires a separately
reviewed migration.

## Required validation before a release

1. Open a pull request targeting `main` and review the complete diff.
2. Confirm the exact PR head SHA and require the following applicable GitHub
   Actions validation jobs to complete successfully on that SHA:
   - Backend regression shards 1/4 through 4/4.
   - `backend-foundation-tests`.
   - `flutter-web-tests` when Flutter web validation is in scope.
   - `authorization-postgres-integration`.
   - `postgres-security-integration` (the disposable PostgreSQL dataset
     security integration covering grant revocation, concurrent approval,
     and transactional publication).
   - `Managed dataset backend regression tests` and
     `Management Cell Flutter regression tests` when their paths or behavior
     are in scope.
   - `postgres-handoff` for Excel authentication PostgreSQL integration when
     Excel authentication changes are in scope.
   - `query-history-tests`, `detail-upload-tests`, and
     `context-state-tests` when their corresponding backend areas are in
     scope.
3. Confirm the `Security scanning` workflow succeeds, including
   `Gitleaks full-history secret scan`, `Python dependency audit`, and
   `OSV dependency scan`.
4. The `Management Cell Responsive UI CI` workflow is path-filtered and is
   required when Flutter application files or that workflow change. Do not
   configure a path-filtered job as an unconditional required check if GitHub
   will leave it pending on unrelated changes.
5. Confirm the `Excel Auth PostgreSQL Integration` and
   `Management Cell Validation` workflows pass when their paths or behavior
   are in scope.
6. Review the complete diff and confirm that Managers can submit only with an
   active branch-specific grant. Only a Branch Head assigned to that same
   branch may approve or reject; only an approved proposal may publish to the
   official dataset. Do not grant Managers direct write access to the
   original dataset.
7. Keep production database migrations manual. The
   `InsightFlow Production Authz Migrations` workflow is dispatched explicitly
   from `main`; it is not triggered by every push. The operator must also set
   `confirm_production_migration` to true for the job to run. Do not dispatch
   it for a release unless a production migration has separately been reviewed
   and approved.
8. Review the exact target commit and deployment plan before manually
   deploying to Render. After deployment, verify the deployed SHA, service
   status, `/health` response, and database readiness.

### Supabase Preview check: expected skip on this Free project

The Supabase organization is on the Free plan and the connected project has
only its persistent `main` branch. The Supabase Preview check's own output
reports that creating a new preview branch per PR is disabled. The check is
therefore skipped because per-PR preview creation is unavailable in this
configuration; it is not a passing test. Supabase documents isolated Preview
Branching as a Pro-plan capability, so this release does not enable preview
branching or incur additional subscription or compute costs.

A skipped Supabase Preview check is not a pass and must never be represented
as one. Under the project's Free-plan and no-cost constraint, it is excluded
from the required release gate. The approved database verification mechanism
is the disposable PostgreSQL integration jobs in GitHub Actions, which must
pass on the exact PR head SHA. Do not create or upgrade a Supabase preview
environment to make this check green. If the project plan or integration
configuration changes, revisit this exception before making Preview a
required check.

## GitHub main branch enforcement

The `main` branch must have an active repository ruleset that:

- Targets `main` and is in Active enforcement mode.
- Requires changes to be proposed through pull requests.
- Requires the applicable, consistently running GitHub Actions checks above.
- Requires the branch to be up to date before merging where supported.
- Blocks force pushes and branch deletion.
- Has no bypass actors and requires zero human approvals for this
  single-maintainer repository.

Do not require Cloudflare Worker or Pages checks: the owner removed the
Cloudflare GitHub integration and these checks are not part of the current
production architecture. Do not require Supabase Preview while the documented
Free-plan limitation applies. Verify the ruleset through GitHub repository
settings or the rulesets API; documentation alone is not evidence that
enforcement is active.

## Production safety

- Never use a production database in CI; CI provisions disposable PostgreSQL.
- Never put production connection strings or secrets in source files or logs.
- Do not run production migrations, change production Auth configuration, or
  deploy automatically as a side effect of a feature-branch push.
- Do not activate the Supabase Auth Hook as part of this release.
- Do not claim an authentication protection is active unless its live
  production configuration has been independently verified.
- The current Render Auto-deploy setting is disabled, so a new GitHub commit
  does not itself deploy the service. Verify the exact commit in Render after
  a manually triggered deployment.
- A documentation-only change does not require a production deployment.
