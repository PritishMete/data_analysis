# InsightFlow release and deployment process

## Canonical deployment source

As verified on 24 November 2026, the existing Render service `data_analysis`
(`https://data-analysis-oajs.onrender.com`) is configured to deploy from
`main`. Its start command is
`uvicorn main:app --host 0.0.0.0 --port $PORT`, its health-check path is
`/health`, and Auto-deploy is disabled.

`main` is the canonical production branch for the backend and release
validation. Do not deploy a feature branch or assume that changing
`render.yaml` updates the existing Render service. Any change to the
production source branch requires a separately reviewed migration.

## Required validation before a release

1. Open a pull request targeting `main` and review the complete diff.
2. Wait for **InsightFlow Backend CI**, including the disposable PostgreSQL
   authorization integration, backend security regression suite, Flutter
   validation, and Flutter web build, to finish successfully on the exact PR
   head SHA.
3. Confirm **PostgreSQL dataset security integration** passes on that same PR
   head SHA. It tests grant revocation, concurrent approval, and transactional
   publication without production data.
4. Confirm **Excel Auth PostgreSQL Integration** and **Management Cell
   Validation** pass when their paths or behavior are in scope. The
   **Management Cell Responsive UI CI** is path-filtered and is required when
   Flutter application files or that workflow change.
5. Confirm **Security scanning** passes, including the full-history Gitleaks
   scan, Python dependency audit, and OSV dependency scan.
6. Review the complete diff and confirm that Managers can submit only with an
   active branch-specific grant. Only a Branch Head assigned to that same branch
   may approve or reject; only an approved proposal may publish to the official
   dataset. Do not grant Managers direct write access to the original dataset.
7. Keep production database migrations manual. The
   **InsightFlow Production Authz Migrations** workflow is dispatched explicitly
   from `main`; it is not triggered by every push. The operator must also set
   `confirm_production_migration` to true for the job to run. Do not dispatch it
   for a release unless a production migration has separately been reviewed and
   approved.
8. Review the exact target commit and deployment plan before manually deploying
   to Render. After deployment, verify the deployed SHA and `/health` response.

### Supabase Preview check: expected skip on this Free project

The Supabase organization is on the Free plan and the connected project has
only its persistent `main` branch. The Supabase Preview check's own output
reports: "Creating a new preview branch per PR is disabled. You can re-enable
it in Project Integrations Settings." The current check is therefore skipped
because per-PR preview creation is disabled; it is not a passing test. Supabase
documents isolated Preview Branching as a Pro-plan capability, so this release
does not enable preview branching or incur additional subscription or compute
costs.

A skipped Supabase Preview check is not a pass and must never be represented as
one. Under the project's Free-plan and no-cost constraint, it is excluded from
the required release gate. The approved database verification mechanism is the
required, disposable PostgreSQL integration jobs in GitHub Actions, which must
pass on the exact PR head SHA. Do not create or upgrade a Supabase preview
environment to make this check green. If the project plan or integration
configuration changes, revisit this exception before making Preview a required
check.

### Cloudflare checks

Cloudflare Workers and Pages are separate deployment integrations. Their
checks must be inspected independently; a successful Pages deployment does
not establish that the Worker build succeeded. Do not make a failed Worker
check optional or remove the Worker until its production usage and build
configuration have been verified from Cloudflare's build details.

## Production safety

- Never use a production database in CI; CI provisions disposable PostgreSQL.
- Never put production connection strings or secrets in source files or logs.
- Do not run production migrations, change production Auth configuration, or
  deploy automatically as a side effect of a feature-branch push.
- The current Render Auto-deploy setting is disabled, so a new GitHub commit
  does not itself deploy the service. Verify the exact commit in Render after a
  manually triggered deployment.
