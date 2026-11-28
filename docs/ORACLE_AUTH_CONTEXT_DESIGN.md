# Oracle cutover: authorization-context design

Status: source audit and proposed implementation/test plan only. This document
does not authorize changes to Oracle, Worker, Render, Supabase, schemas,
policies, credentials, or live data.

## Findings

### Identity and session restoration

- Supabase Auth is the client identity authority. `ensureSession()` waits for a
  restored auth state, refreshes a session that expires within 30 seconds, and
  returns no bearer token when restoration or refresh fails.
- The verified Supabase subject is the stable identity key. The backend must
  continue deriving principal, organization, membership, role, and permissions
  from the verified bearer token and authorization store.
- `resolveInsightFlowOnboardingStateFromBackend()` treats `/v1/authz/me` as the
  authoritative post-auth contract. It persists the returned active
  `workspace_id` only after it matches an active entry in `workspaces`.
- `insightFlowWorkspaceId` and `insightflow.workspace.<uid>` are a selected
  workspace hint/continuity cache, not an authorization grant. A stale cache is
  cleared on authoritative denial or loss of membership.

### Canonical context sources

| Context | Canonical source | Client use | Server requirement |
| --- | --- | --- | --- |
| Identity | Verified Supabase bearer token | `ensureSession()` / `supabaseAuthHeaders()` | Verify token and email verification; derive subject |
| Workspace | `/v1/authz/me` active membership response | Store selected active `workspace_id` | Re-resolve membership for the bearer subject; never trust header alone |
| Resource | Managed-dataset route ID or an authorized resource selected from server response | Send `X-InsightFlow-Resource-ID` only for generic resource routes | Check resource ownership/grant in the selected organization/workspace |
| Managed dataset | `/v1/managed-datasets` authorized catalogue and route IDs | Use returned dataset/working-copy IDs | Use `dataset_authorization`, `resource_grants`, lifecycle, and branch scope |
| Ad-hoc upload | Local file bytes selected in the current UI session | No invented dataset/resource ID | Treat multipart ingress as `dataset.upload`; do not infer ownership from filename or client metadata |

The workspace header is therefore a selector that must be reconciled server-side;
it is not a replacement for the verified identity or membership lookup.
The concrete headers in the current contract are `X-InsightFlow-Workspace-ID`
and `X-InsightFlow-Resource-ID`.

### Existing authenticated HTTP infrastructure

`apps/flutter_app/lib/core/auth/authenticated_http.dart` provides the reusable
boundary. `supabaseAuthHeaders()` calls `ensureSession()`, emits the bearer and
the current workspace header, and optionally emits a validated resource header.
The same file contains authenticated request helpers for workspace/resource and
managed-dataset operations. Existing managed-dataset UI code also obtains
Supabase headers and adds the workspace selector before calling the protected
routes.

The named services below do not currently use that infrastructure:

| Service | Current routes | Current context | Cutover requirement |
| --- | --- | --- | --- |
| `chat_reasoning_service.dart` | `/v1/chat/plan` | JSON only | Attach restored Supabase auth context and the selected resource/workspace contract, or explicitly classify as local-only if backend policy remains public (it is currently middleware-protected) |
| `conversation_state_service.dart` | `/v1/assistant/meta`, `/v1/conversation/*` | Session ID and local structured state only | Decide whether state is per authenticated user/workspace/resource; then use the common authenticated client and server-side ownership checks |
| `powerbi_detail_analysis_service.dart` | `/powerbi/*` multipart | File bytes only | Use authenticated multipart requests; ad-hoc uploads must be authorized as `dataset.upload` and must not claim a managed dataset ID |
| `system_diagnostics_service.dart` | `/v1/system/diagnostics` | Build ID query only | Decide whether diagnostics is a public deployment probe or an authenticated tenant operation; do not silently weaken the default-protected route |

## Protected endpoint requirements

The authorization middleware requires a non-empty Supabase bearer, an active
workspace context, and (for generic resource policies) a resource context. It
maps route actions server-side; clients cannot choose the required permission.
Multipart POST/PUT/PATCH requests receive an additional `dataset.upload`
authorization check. Managed-dataset routes are special-cased so their service
layer can resolve route dataset IDs and enforce the full branch/resource policy.

The current middleware route table protects `/v1/chat/plan`, `/powerbi/*`,
`/v1/assistant/meta`, and the Excel analysis routes. Conversation-state routes
are not listed in the explicit action table and consequently fall through to
the default protected policy. This makes the current unauthenticated Flutter
calls incompatible with the protected endpoint contract.

## Valid ad-hoc upload flow

Ad-hoc files are not managed datasets. The safe flow is:

1. Restore/refresh the Supabase session.
2. Resolve and select an active workspace from `/v1/authz/me`.
3. Send the bearer and workspace selector through an authenticated multipart
   request. Do not send a guessed resource or dataset ID.
4. Let middleware authorize `dataset.upload`; the endpoint may analyze bytes in
   memory but must not persist them as a managed dataset unless the explicit
   managed-dataset workflow is used.
5. For managed data, use the catalogue/proposal/upload-scope flow and returned
   IDs. Branch Head and explicitly granted Manager uploads remain subject to
   the existing location/branch checks; Organization Owner is read-only for
   original dataset writes.

## Cross-workspace risks

- Reusing a cached workspace after membership changes can mix tenant context;
  every protected request must use the current authoritative selection and the
  backend must re-check membership.
- Passing a dataset ID from workspace A with workspace B's header must fail at
  both the workspace/resource authorization boundary and the dataset ownership
  boundary.
- Conversation IDs, working-copy IDs, and ad-hoc upload state must not be used
  as implicit authorization. Server-side ownership must bind them to the
  authenticated principal/workspace/resource.
- Generic `X-InsightFlow-Resource-ID` must not override a managed-dataset route
  ID or turn a workspace-only permission into original-dataset access.
- Diagnostic/build identifiers are not tenant selectors and must never be
  treated as ownership evidence.

## Proposed implementation plan

1. Introduce or extend one authenticated HTTP abstraction that supports JSON
   and multipart requests, calls `ensureSession()` before constructing headers,
   and carries workspace/resource context without inventing IDs.
2. Migrate the four named services one at a time. Preserve endpoint paths and
   response parsing; only add the contract-required auth/context plumbing.
3. Add explicit service/route ownership decisions for conversation sessions
   and diagnostics before changing their callers. If diagnostics remains a
   public health probe, remove it from the protected API contract only through
   a separately reviewed backend policy change.
4. Keep ad-hoc Power BI/detail-analysis requests distinct from the managed
   dataset catalogue. Never add a client-generated dataset ID.
5. Add backend contract tests for 401/403 behavior, workspace mismatch,
   resource mismatch, cross-workspace dataset IDs, and multipart upload scope.
   Use synthetic tokens/fixtures and disposable databases only.

## Proposed test matrix

- Restored session: bearer is present only after `ensureSession()` succeeds;
  near-expiry sessions refresh before the request.
- Missing/expired session: no request is sent, or the request receives the
  existing authentication failure without logout side effects for a valid
  identity.
- Active workspace: `/v1/authz/me` selection is persisted and stale cached
  workspace values are rejected/cleared.
- Header contract: protected JSON and multipart requests include bearer and
  workspace; resource header appears only when a canonical resource ID exists.
- Cross-workspace: synthetic workspace A/B and dataset/resource IDs cannot be
  mixed successfully.
- Managed dataset: catalogue IDs, route IDs, branch/location scope, grants,
  and lifecycle status remain authoritative.
- Ad-hoc upload: multipart `dataset.upload` succeeds only for an authorized
  synthetic principal and never relies on filename, client metadata, or a
  guessed ID.
- Service coverage: each named service has request-capture tests for path,
  method, auth headers, context headers, and safe failure mapping.

## Product decisions required

1. Are conversation states scoped to the authenticated principal, workspace,
   resource, or an intentionally local device session? The source currently
   exposes a bare session ID and an in-memory backend store, so ownership is
   not defined by the client contract.
2. Is `/v1/system/diagnostics` a public deployment-health probe or a protected
   tenant diagnostic? The route is middleware-protected today, while the
   Flutter service sends only a build ID.
3. Should `/v1/assistant/meta` be a public, privacy-safe static-help endpoint,
   or remain protected under the default middleware policy?
4. Should Power BI/detail-analysis remain ephemeral ad-hoc analysis, or should
   it become a managed-dataset ingestion path? The current source implements
   the former; the cutover must not silently change that product behavior.
5. When a user has multiple active workspaces, what UI action is authoritative
   for switching workspaces, and which active resource/session state must be
   discarded on the switch?
