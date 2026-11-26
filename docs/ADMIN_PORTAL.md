# Independent administrator portal

The administrator UI lives at the repository-level `apps/admin_portal/` and is deployed as the separate Cloudflare Pages project `insightflow-admin`. It is not mounted by the Flutter application and has no public-app navigation path.

The UI calls the existing FastAPI service at `/v1/admin/*`. Supabase Auth supplies the bearer token; FastAPI verifies it and resolves the authenticated subject through `identity_bindings`. Access requires an active `organization_owner` assignment or an explicit active row in `diagnostic_support_admins`. Organization and branch scope are checked server-side for every request. Cloudflare Access, if added later, is only a perimeter layer and must not replace these checks.

Migration `0042_diagnostic_admin.sql` adds diagnostic sessions/events and explicit support-admin scope to the existing Supabase project. Apply it only through `tools/run_authz_migrations.py` after review; this change does not run production migrations. Diagnostic rows are separate from `audit_events`; administrator views and exports are written to the existing audit mechanism.

Cloudflare Pages settings: root `apps/admin_portal`, build `npm run build`, output `dist`, production branch `main`, and watch paths limited to `apps/admin_portal/**` plus the admin backend/migration paths. No production deployment is authorized by this change.
