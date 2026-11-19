# Excel v2 authentication handoff

This document describes the versioned Excel task-pane handoff. It does not change the
website's normal Supabase authentication flow.

## Token lifecycle

- The browser completes Supabase OAuth PKCE in one top-level browser context. Its
  PKCE verifier must survive the provider redirect in the browser's session-scoped
  verifier storage. Configure the transient browser auth client with
  `persistSession: false` and `autoRefreshToken: false`; do not persist access or
  refresh tokens in localStorage or sessionStorage.
- The browser posts its access token to `browser/candidate`. The API validates it
  using the existing Supabase JWKS/Auth /user verifier. The API stores the resulting
  UID and generation; it never accepts a browser-supplied UID as identity.
- Excel reads that candidate and explicitly approves that exact UID and generation.
- After approval, the browser posts the access/refresh token pair to
  `browser/complete`. The API re-verifies the access token and checks that its UID
  is the approved UID before encrypting and staging the refresh token.
- The backend does not call Supabase's refresh endpoint. It cannot rotate the token,
  and it does not rely on the parent-token reuse window. The refresh token remains
  encrypted at rest until Excel claims it.
- Claim locks the PostgreSQL row, decrypts before changing state, marks it claimed,
  clears ciphertext, and commits before returning the refresh token. The Excel
  instance identifier is correlation metadata only; the 256-bit claim capability
  is the sole authority for claim.
- Flutter passes the returned refresh token to Supabase `setSession`, then calls
  `getUser` and compares the actual UID with the approved UID. On mismatch or
  failure it must clear only its local session and require a new handoff.
- A lost claim response is never replayed. The user starts a new sign-in.

The refresh token is not verifiably bound to the access token without consuming or
rotating it through Supabase. Therefore final UID verification after `setSession`
is mandatory. The browser client must clear its in-memory session after successful
staging. The backend never logs request bodies or token material.

## Expiration and cancellation

No Supabase refresh operation is in flight in the backend. Expiration can therefore
terminalize any unclaimed v2 transaction and clear its staged ciphertext. Cancellation
does the same. PostgreSQL row locking serializes completion, cancellation and claim.
A claim already committed is terminal and cannot be cancelled or replayed.

## API

All endpoints are POST under `/v2/excel-auth/handoff`:

- `create`
- `browser/bind`
- `browser/candidate`
- `status`
- `approve`
- `browser/complete`
- `claim`
- `cancel`
- `retry`

The v1 router is not mounted by this version, so its direct-token completion path
cannot bypass v2 approval. Migration `0038_excel_auth_pairing.sql` is additive to
`0037_excel_auth_handoff.sql`. Neither migration is applied to production by CI.

## Required server settings

- `INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY`: canonical URL-safe base64 encoding
  of exactly 32 random bytes.
- `INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY`: at least 32 bytes of independent random
  secret material, used only as the HMAC key for pairing-code digests.
- Existing Supabase URL and publishable key settings used by the shared token
  verifier.

The production backend database connection must use PostgreSQL. SQLite is rejected
for v2 because its locking semantics are not accepted for one-time claims. Confirm
the deployed database role has only the required access to the private schema.
Do not apply migration 0038 until the production database role and migration 0037
state have been independently verified.

## Host limitations

The backend API does not itself prove Windows Excel Desktop compatibility. Office
Dialog and external browser behavior, including redirect/callback handling, must be
accepted on the actual supported Excel Desktop host before release.
