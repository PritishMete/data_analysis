# Oracle cutover privacy and security inventory

Audit basis: PR #136 head `62641340598bca75de90e254c0cac2f2a2abde7c`.
This is a source-level audit with synthetic/read-only checks only. No live
credentials, production data, database schema, Worker deployment, Render
service, or Supabase settings were changed.

## Data-flow inventory

| Flow | Local behavior | Remote behavior | Privacy/security boundary |
| --- | --- | --- | --- |
| Excel active selection / named sheet | Flutter/Office.js reads the selected range and worksheet context locally. | Analysis routes receive the selected context when the feature calls the backend. | Workbook data is not protected merely because the UI is local; every remote call needs the authenticated workspace/resource contract. |
| File upload / Power BI detail analysis | `SourceRouter` picks bytes with `FilePicker`; the Flutter service keeps the selected bytes in memory until upload. | `/powerbi/detail-analysis` and related `/powerbi/*` routes parse files in memory, derive profiles/model results, and may warm a business-analysis model. | Raw bytes cross the client-to-Oracle boundary. The backend reports source hashes and unchanged-source flags; hashes are metadata, not anonymization. |
| Power BI cleaning/date/dashboard | Input is selected locally and sent as multipart data. | `/powerbi/customer-clean`, `product-clean`, `order-clean`, `date-dimension`, `business-analysis`, and `dashboard` process data server-side. Generated PDF reports are written to the Oracle VM temp directory and served through `/powerbi/reports/{filename}`. | Report names are opaque and route authorization is required, but temp-file retention/cleanup and report ownership need an operational policy. |
| Chat planning | Flutter sends only the query, allowlisted abstract dataset roles, capabilities, and bounded prior intent. | `/v1/chat/plan` is deterministic by default; Gemini is opt-in and receives metadata-only planner input when both feature flags permit it. | The query is still user text and can contain PII unless product policy rejects/redacts it. Logs currently include the query at debug level; production logging policy must be confirmed. |
| Conversation state | Flutter creates a session ID and sends bounded analytical context/update/snapshot data. | `/v1/conversation/*` stores process-local structured state in `common.conversation_state`; no dataset values are required by the contract. | The current route handlers do not establish ownership from the session ID themselves. Middleware protects them by default, but the Flutter service does not attach auth/workspace headers. Cross-user session enumeration must remain impossible at the deployed boundary. |
| System diagnostics | Flutter sends only the served build ID. | `/v1/system/diagnostics` returns build/health metadata. | Diagnostics are not dataset content, but must not become an unauthenticated information oracle. The current Flutter service omits auth headers while the default middleware protects unknown routes. |

## Local versus remote conclusions

The local-first claim is accurate for worksheet scanning and deterministic
routing only. A user selecting “Detail Analysis”, Power BI cleaning, business
analysis, chat planning, or conversation synchronization crosses the Oracle
gateway. The gateway forwards request method, path, query, body, authorization,
and relevant headers to the Oracle VPC upstream. It does not make uploaded
content local, redact it, or authorize it.

The current Power BI service also displays selected filenames and the returned
report in the Flutter UI. Filenames and query text should be treated as user
data; neither should be included in telemetry or debug logs without an explicit
redaction policy.

## Auth, workspace, abuse protection, and CORS

- The Worker accepts the configured Pages origin only. A request with a
  different `Origin` is rejected with 403; a request with no `Origin` is
  forwarded. Missing `Origin` is therefore not authentication.
- CORS controls browser permission to read a response. It does not authenticate
  a caller. FastAPI authentication independently requires a Supabase bearer
  token, verified email, workspace header, and route-specific resource/action
  authorization.
- Unknown routes default to `analysis.run` with resource authorization. The
  Power BI family requires `analysis.run` and a resource; the dashboard route
  requires `worksheet.create`; chat planning requires `analysis.run` and a
  resource. Multipart uploads additionally require `dataset.upload`.
- The database-backed limiter classifies `/powerbi/*` and related expensive
  routes under the configurable expensive per-minute bucket. The limiter is
  keyed by the directly connected peer, not a client-supplied forwarded IP.
  Request-size middleware caps bodies; the default is 100 MiB and the maximum
  configured ceiling is 500 MiB.
- `OriginProtectionMiddleware` rejects disallowed state-changing origins and
  rejects cookie-authenticated state-changing requests without an Origin. It
  intentionally does not reject originless bearer requests. If originless
  non-browser abuse is in scope, product/operations must choose a separate
  control such as gateway authentication/rate policy or mTLS; CORS cannot do it.

## Cutover finding requiring a product-owner decision

The scoped Flutter services `powerbi_detail_analysis_service.dart`,
`chat_reasoning_service.dart`, `conversation_state_service.dart`, and
`system_diagnostics_service.dart` currently construct requests directly and do
not attach `Authorization`, `X-InsightFlow-Workspace-ID`, or (where required)
`X-InsightFlow-Resource-ID`. This is consistent with their old local/legacy
assumptions but is incompatible with the protected Oracle route contract.

Before changing these services, the owner must decide:

1. Which authenticated workspace and resource represent an ad-hoc Power BI
   upload and chat/conversation session?
2. Whether diagnostics should require the normal workspace session or expose a
   narrowly scoped public health/build endpoint instead.
3. Whether conversation state is intentionally process-local and ephemeral, or
   must be tenant-owned and durable with explicit retention/deletion rules.
4. Whether remote Power BI processing is allowed by default, or requires an
   explicit consent/privacy-mode gate and a maximum file/count/row policy.
5. What report-temp retention, cleanup, and incident access policy applies on
   Oracle.

No Flutter auth correction is included in this audit because selecting a
resource identifier or weakening route protection would be an authorization
decision, not a safe mechanical fix.

## Out of scope

No admin panel, PR #135/#136/#137, production infrastructure, Worker
deployment, Supabase schema/credentials, Render, or broad auth redesign was
changed.
