# Oracle cutover local-first remediation

## Decision

No Power BI upload flow is switched back to loopback in this change.

The Flutter Power BI client uploads selected file bytes through
`PowerBiDetailAnalysisService`. At the starting commit, all of its detail
analysis, customer/product/order cleaning, date-dimension, business-analysis,
dashboard, and report-generation endpoints are composed from
`insightFlowBackendOrigin`, which defaults to the Cloudflare gateway backed by
Oracle.

The former local URLs (`http://127.0.0.1:8000/powerbi/...`) point to the same
FastAPI route family. `firebase_authz.middleware` protects `/powerbi/` with
`analysis.run` and a resource context; multipart requests additionally require
the server-side `dataset.upload` capability. The Power BI Flutter client does
not provide a bearer token, workspace ID, or resource ID for these requests.
Routing the bytes to a local instance would therefore fail authentication, or
would require weakening the existing authorization boundary and guessing an
ID. Neither is safe or authorized.

## What remains safely local

Existing local processing remains unchanged:

- Secure Excel query and synthetic-data operations execute in the Office
  taskpane and do not send worksheet rows to Python or a remote service.
- Deterministic categorization, currency conversion, and the local pipeline
  operate on the in-memory dataset; the optional LLM provider is loopback-only.
- Detail Analysis intent classification and conversation follow-up resolution
  are deterministic Flutter logic and do not inspect or upload dataset values.

These are distinct from the Power BI multipart workflows and must not be
described as making Power BI uploads local.

## Product decision required before any future local Power BI path

The product must choose an explicit local deployment contract that preserves
authentication and authorization (including how workspace/resource scope is
established), or explicitly approve a separate offline-only mode with its own
security model. Until then, Power BI privacy wording says that selected files
are sent to the configured InsightFlow backend; result wording says only that
source files are not modified.

No production infrastructure, Worker, Oracle, Render, Supabase, admin panel,
credentials, schema, or live data was changed.
