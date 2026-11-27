# Independent administrator portal

The administrator UI lives at the repository-level `apps/admin_portal/` and is deployed as the separate Cloudflare Pages project `insightflow-admin`. It is not mounted by the Flutter application and has no public-app navigation path.

The UI calls the existing FastAPI service at `/v1/admin/*`. Supabase Auth supplies the bearer token; FastAPI verifies it and resolves the authenticated subject through `identity_bindings`. Access requires an active `organization_owner` assignment or an explicit active row in `diagnostic_support_admins`. Organization and branch scope are checked server-side for every request. Cloudflare Access, if added later, is only a perimeter layer and must not replace these checks.

Migration `0042_diagnostic_admin.sql` adds diagnostic sessions/events and explicit support-admin scope to the existing Supabase project. Application startup never runs migrations. Inspect with `python tools/run_authz_migrations.py --inspect`; apply development migrations explicitly with `python tools/run_authz_migrations.py`, or apply production migrations only with `INSIGHTFLOW_ENV=production python tools/run_authz_migrations.py --confirm-production` after separate owner approval. Diagnostic rows are separate from `audit_events`; administrator views and exports are written to the existing audit mechanism. Failed migrations return nonzero and should be rolled back using the database backup/runbook before retrying.

Cloudflare Pages settings: root `apps/admin_portal`, build `npm run build`, output `dist`, production branch `main`, and watch paths limited to `apps/admin_portal/**` plus the admin backend/migration paths. No production deployment is authorized by this change.


## Company-wide backend request metric

The company-wide overview's Backend requests and Backend errors figures are derived from
`platform_backend_events`. The figure represents customer-facing backend API request
telemetry, not the Render service's platform-level HTTP request total. The overview and
Backend Request Logs endpoint use the same route scope: company-admin, admin-control,
diagnostic-session, health, and documentation routes are excluded. The customer event
ingestion route `/v1/admin/events` remains included.

Older control-plane requests may already exist in `platform_backend_events` from
deployments before the middleware exclusion was introduced. They remain stored for
history and are excluded from customer metrics and the customer request-log view at
read time. This correction does not delete or rewrite telemetry records and requires
no production database migration.
