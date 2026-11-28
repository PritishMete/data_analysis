# Authenticated transport

`AuthenticatedHttpTransport` is the reusable boundary for protected JSON and multipart requests over `package:http`. It also exposes the same authenticated headers for Dio callers. Each request obtains the restored/refreshed Supabase session through `ensureSession`, requires the authoritative workspace context and a nonblank canonical resource ID, and fails before network I/O when either context is unavailable. Resource IDs are passed through exactly as supplied after trimming outer whitespace; no fallback IDs are fabricated.

Existing production services, including the file upload and Power BI/Detail Analysis multipart callers, are intentionally not migrated by this change because their current call sites do not establish a canonical resource identity. Agent A should pass the `/v1/authz/me` workspace/resource context into those callers before migration; no public/OAuth endpoint should use this boundary.
