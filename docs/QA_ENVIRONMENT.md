# Isolated QA environment

The QA deployment must use the existing Supabase project `xcnjauxmofqkwnpdazpj`
and its independently verified PostgreSQL endpoint
`db.xcnjauxmofqkwnpdazpj.supabase.co`. The production project's database
endpoint is separately identified as
`db.zfdgwnipdyrpbardqoql.supabase.co`. The QA guard pins both identities in
code; changing the environment allowlist alone cannot redirect QA to production
or to an arbitrary database host.

`core.qa_environment` runs before application database initialization when
`INSIGHTFLOW_ENV=qa`. It rejects the production project/database, arbitrary
database hosts, SQLite, missing configuration, mismatched providers, and
unapproved Supabase URLs.

The QA process must use a separate checkout, virtual environment, environment
file, systemd unit, and loopback listener (`127.0.0.1:8100`). It must not reuse
the production environment file or `data-analysis.service`, and it must not be
published through Cloudflare.

## Migration inventory

The current `main` tree contains migrations through `0045`, including:

- `0042_diagnostic_admin.sql`
- `0043_insightflow_company_admin.sql`
- `0044_platform_backend_events.sql`
- `0045_backend_error_stack.sql`

The repository tree was checked at main commit
`6cc83a251c4ac4d008fcd6b21f2fbfb1a11640c5`. These files are present in the
repository; their presence does not mean they have been executed in the QA
project. Review the complete migration history and dependency order before
approving any QA schema application.

## Required approval before provisioning

1. Confirm the Supabase organization plan and billing status.
2. Confirm that the QA project may receive the reviewed InsightFlow schema.
3. Approve the exact migration set and its QA-only execution.
4. Supply QA-only secrets through protected local/server configuration.

No QA migrations or schema provisioning are performed by this setup guide.
