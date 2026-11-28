# Authenticated transport

`AuthenticatedHttpTransport` is an opt-in boundary for future protected callers. It obtains the restored or refreshed Supabase session, resolves the canonical workspace from authenticated `/v1/authz/me`, and treats the cached workspace ID only as a selector hint. A protected request is sent only after `/v1/authz/me` proves active membership and the caller supplies a `CanonicalResource` parsed from a server response for that workspace.

Use `getJson`, `postJson`, `postMultipart`, or `dioHeaders`. `CanonicalResource.fromServerJson` accepts `resource_id`, `dataset_id`, or `working_copy_id` together with `workspace_id` and rejects missing or terminal records. Session, authorization, membership, or context failures stop before the protected request and never log credentials or response bodies.

Chat, Power BI/detail-analysis, upload, health, and build callers are intentionally not migrated here until consent and resource context are defined. The default backend origin is unchanged.
