# InsightFlow release and deployment process

## Canonical deployment source

As verified on 25 October 2026, the existing Render service `data_analysis`
(`https://data-analysis-oajs.onrender.com`) is configured to deploy from
`feature/employee-management-cell`. Its start command is
`uvicorn main:app --host 0.0.0.0 --port $PORT`, its health-check path is
`/health`, and Auto-deploy is disabled.

Until a reviewed release migration changes that live service configuration,
`feature/employee-management-cell` is the canonical branch for the Management
Cell backend and its release validation. Do not deploy `main` or
`feature/data-workspace` as substitutes. The repository's default branch is
`main`, but default-branch status does not mean its code is equivalent to the
active deployment branch. Branches are substantially diverged; synchronize
through a reviewed pull request after a deliberate comparison, never a wholesale
historical merge.

## Required validation before a release

1. Push the intended changes to `feature/employee-management-cell`.
2. Wait for **InsightFlow Backend CI**, including the disposable PostgreSQL
   migration/startup tests, the backend security regression suite, and Flutter
   validation, to finish successfully on the exact commit.
3. Confirm the PostgreSQL dataset-security integration workflow passes on that
   commit. It tests grant revocation, concurrent approval, and transactional
   publication without using production data.
4. Review the complete diff and confirm that Managers can submit only with an
   active branch-specific grant. Only a Branch Head assigned to that same branch
   may approve or reject; only an approved proposal may publish to the official
   dataset. Do not grant Managers direct write access to the original dataset.
5. Keep production database migrations manual. The
   **InsightFlow Production Authz Migrations** workflow is dispatched explicitly
   from `feature/employee-management-cell`; it is not triggered by every push. The
   operator must also set `confirm_production_migration` to true for the job to run.
   Configure required reviewers on the GitHub `production` environment before
   using the workflow if approval gates are required by the release policy.
6. Review the target commit and deployment plan before manually deploying to
   Render. Do not deploy from a stale branch or assume that editing `render.yaml`
   updates an existing Render service.

## Production safety

- Never use a production database in CI; CI provisions disposable PostgreSQL.
- Never put production connection strings or secrets in source files or logs.
- Do not run production migrations, change production environment variables, or
  deploy automatically as a side effect of a feature-branch push.
- The current Render Auto-deploy setting is disabled, so a new GitHub commit
  does not itself deploy the service. Verify the exact commit in Render after an
  operator performs a deployment.
