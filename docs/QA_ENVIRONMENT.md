# Isolated QA environment

The QA deployment must use the existing Supabase project `xcnjauxmofqkwnpdazpj`
and a separately allowlisted PostgreSQL host. `core.qa_environment` runs before
application database initialization when `INSIGHTFLOW_ENV=qa` and rejects the
production project, SQLite, missing configuration, mismatched providers, and
database hosts that are not explicitly allowlisted.

The QA process must use a separate checkout, virtual environment, environment
file, systemd unit, and loopback listener (`127.0.0.1:8100`). It must not reuse
the production environment file or `data-analysis.service`, and it must not be
published through Cloudflare.

Required approval before provisioning:

1. Confirm the Supabase organization plan and billing status.
2. Confirm that the QA project may receive the reviewed InsightFlow schema.
3. Approve the exact migration set and its QA-only execution.
4. Supply QA-only secrets through protected local/server configuration.

The current repository checkout contains migration files through `0042`, while
historical Git objects also contain `0043`–`0045`; reconcile those files against
the approved release before any QA migration is run.
