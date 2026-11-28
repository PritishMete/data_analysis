# Authenticated transport

`AuthenticatedHttpTransport` is the reusable boundary for protected JSON and multipart requests. Each request obtains the restored/refreshed Supabase session through `ensureSession`, requires the authoritative workspace context and a nonblank canonical resource ID, and fails before network I/O when either context is unavailable. Resource IDs are passed through exactly as supplied after trimming outer whitespace; no fallback IDs are fabricated.

Existing production services are intentionally not migrated by this change.
