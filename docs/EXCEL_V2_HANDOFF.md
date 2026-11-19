# Excel v2 authentication handoff

This document describes the versioned Excel task-pane handoff. It does not change the
website's normal Supabase authentication flow.

## Token lifecycle

- The browser performs Supabase OAuth PKCE in one top-level browser context. Its
  PKCE verifier is held in sessionStorage across the provider redirect. The bridge
  calls Supabase Auth's PKCE token endpoint directly; it does not create a persistent
  browser Supabase client. Access and refresh tokens remain in a transient JavaScript
  session object only and are never written to localStorage or sessionStorage.
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

The refresh token is not independently verifiable without consuming or rotating it
through Supabase. Therefore final UID verification after `setSession` is mandatory.
The bridge clears the access and refresh token fields from its transient session
object after each handoff attempt. The backend never logs request bodies or token
material.

## Expiration and cancellation

No Supabase refresh operation is in flight in the backend. Expiration can therefore
terminalize any unclaimed v2 transaction and clear its staged ciphertext. Cancellation
does the same. PostgreSQL row locking serializes completion, cancellation and claim.
A claim already committed is terminal and cannot be cancelled or replayed.

## API

All endpoints are POST under `/v2/excel-auth/handoff`:

- `create` (requires an `Idempotency-Key`; duplicate keys return a safe outcome-unknown conflict and never return capabilities)
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
`0037_excel_auth_handoff.sql`. The general organization/authorization startup migration runner explicitly excludes these Excel-specific files. Neither migration is applied to production by CI.

## Required server settings

- `INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY`: canonical URL-safe base64 encoding
  of exactly 32 random bytes.
- `INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY`: at least 32 bytes of independent random
  secret material, used only as the HMAC key for pairing-code digests.
- Existing Supabase URL and publishable key settings used by the shared token
  verifier.

The production backend database connection must use PostgreSQL. SQLite is rejected
for v2 because its locking semantics are not accepted for one-time claims. The
connected InsightFlow Supabase project is active, but its project metadata does not
expose the Auth access-token lifetime or refresh-token settings. Verify that the
configured access-token lifetime exceeds the maximum approval window before rollout.
If the access token expires before browser/complete, the backend rejects the request
and the user must begin a new sign-in; the backend never refreshes it. This design
does not depend on parent-refresh-token reuse. Confirm
the deployed database role has only the required access to the private schema.
Do not apply migration 0038 until the production database role and migration 0037
state have been independently verified.

## Host limitations

The backend API does not itself prove Windows Excel Desktop compatibility. Office
Dialog and external browser behavior, including redirect/callback handling, must be
accepted on the actual supported Excel Desktop host before release.

## Windows Excel Desktop acceptance checklist

Use the real signed add-in manifest and the deployed backend only after the approved
production migration and server secrets have been configured. Do not treat browser
tests or Flutter Web tests as Excel acceptance.

1. Sideload the manifest into Windows Excel Desktop and open a workbook.
2. With an existing valid session, confirm the add-in restores the user and reaches
   the workspace only after the authoritative Supabase user check.
3. Sign out locally, reload the task pane, create a new handoff and copy the browser
   link. Open it in Chrome or Edge, enter the displayed pairing code and sign in by
   email/password. Approve the displayed email in Excel and verify workspace access.
4. Repeat using Google OAuth. Confirm the provider callback returns to the same
   browser tab, the authorization code is removed from the address bar, and Excel
   receives only the completion notification from Office Dialog.
5. Sign in with a different account than intended, verify the email shown in Excel,
   reject it and confirm no session is established.
6. Approve only after verifying the exact UID/email shown. Confirm the app's final
   getUser() identity matches the approved UID.
7. Reload the task pane while a browser login is pending. Confirm the transaction
   resumes without generating a second claim.
8. Close the browser before candidate submission, then retry with a newly generated
   pairing code. Confirm the previous browser capability is rejected.
9. Let a transaction expire and verify it cannot be claimed and its ciphertext is
   cleared by the status/cleanup path.
10. Complete login, log out from Excel, close Excel, reopen the workbook and verify
    local logout and existing-session restoration behavior separately.
11. Repeat with the Office Dialog fallback. Close the dialog mid-flow and verify
    the transaction can be cancelled or restarted without any token in a dialog
    message.

Record the Windows version, Excel build/channel, manifest version, browser version,
backend commit, Supabase access-token lifetime, test timestamps and outcome for each
case. The current manifest still contains the documented placeholder add-in GUID;
replace it with the stable owner-assigned GUID before formal sideload acceptance.