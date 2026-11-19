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
- Excel logout clears the task-pane handoff capability and signs out with Supabase
  local scope only; it does not revoke sessions in other InsightFlow clients.

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
does not depend on parent-refresh-token reuse. The migrations also expect the PostgreSQL roles `anon` and `authenticated` to exist
(as they do in Supabase). Confirm those roles exist, the actual `DATABASE_URL` points
to the intended database, migration 0037 is present, and the deployed backend role
has only the required access to the private schema. Do not apply migration 0038 until
these production database facts have been independently verified.

## Host limitations

The backend API does not itself prove Windows Excel Desktop compatibility. Office
Dialog and external browser behavior, including redirect/callback handling, must be
accepted on the actual supported Excel Desktop host before release.

## Local Windows Excel Desktop acceptance

This is the first Windows acceptance stage and is local-only. It uses a fresh
disposable PostgreSQL database, local migrations `0037` and `0038`, a locally
running HTTPS backend, a localhost task pane, and the generated runtime
manifest. Render deployment and production database migrations are not
prerequisites for local Windows acceptance; production rollout is a separate
later stage.

### Local prerequisites

The local procedure requires:

- Windows 11.
- Microsoft Excel Desktop and Edge WebView2.
- Compatible Flutter stable and Dart SDK versions.
- Python and the repository Python dependencies.
- Node.js/npm.
- PostgreSQL 16 client and server.
- `mkcert`.

The preparation script checks required command-line tools, but it does not
establish that Excel Desktop or Edge WebView2 is installed.

### Verify the exact checkout before preparation

From the repository root, run:

```powershell
git fetch origin excel-v2-session-handoff
git status --short --branch
git rev-parse HEAD
git rev-parse origin/excel-v2-session-handoff
git diff --check
```

Stop if the local `HEAD` differs from `origin/excel-v2-session-handoff`, or if
the working tree is not the exact state intended for testing. The preparation
script prints the current branch and `HEAD`, but does not fetch, synchronize,
compare, pull, rebase, or switch branches.

### Run the preparation script

Run the script from the repository root with the exact owner-approved GUID and
development Supabase configuration:

```powershell
.\scripts\windows\Prepare-InsightFlowExcelV2.ps1 `
  -SupabaseUrl '<development Supabase URL>' `
  -SupabasePublishableKey '<development publishable key>' `
  -AddinGuid '<owner-approved GUID>'
```

The script requires PostgreSQL 16, verifies that PostgreSQL is reachable,
requires unused backend and task-pane ports, creates a fresh disposable
database, and refuses to modify an existing database. It applies migration
`0037` followed by migration `0038`, generates local-only secrets, creates
local HTTPS certificates, generates the runtime manifest, builds the task pane,
starts the backend and task-pane server, and verifies their health.

`mkcert -install` installs a local development certificate authority into the
Windows trust store. Windows elevation or a trust confirmation may be required.

The script writes the generated runtime manifest to:

```text
%LOCALAPPDATA%\InsightFlow\ExcelV2\OfficeAddins\InsightFlow.localtest.addin.xml
```

It substitutes the approved GUID and local pane URL into that runtime copy. It
does not modify either tracked manifest.

After backend startup and health verification, the script clears backend-related
environment variables from the current PowerShell process. It also performs
this cleanup in documented error paths. This does not delete or alter the
environment inherited by an already-running backend child process.

A successful run leaves the fresh disposable PostgreSQL database in place. The
owner must remove it manually after testing, when its contents are no longer
needed:

```powershell
dropdb -h 127.0.0.1 -p 5432 -U postgres insightflow_excel_test
```

The example uses the default `-DbUser postgres` and
`-DbName insightflow_excel_test`. If either parameter was customized when
running the script, substitute the exact customized values. The script does
not drop the database automatically.

### Local authentication and OAuth prerequisites

Use a dedicated development Supabase project and its publishable/anonymous key.
In Supabase Auth URL Configuration, add the exact local redirect
`https://localhost:3000/` or a narrowly scoped localhost pattern. Keep the
production Site URL unchanged.

For Google OAuth, configure `https://localhost:3000` as the Authorized
JavaScript origin. Configure the Google Authorized redirect URI as the Supabase
provider callback, normally
`https://<PROJECT_REF>.supabase.co/auth/v1/callback`. The provider callback is
not the task-pane redirect. Keep production OAuth settings unchanged during
local testing.

Local acceptance requires the owner-approved stable add-in GUID. The tracked
`apps/flutter_app/excel/InsightFlow.localtest.addin.xml` is only the source
template. The script substitutes the approved GUID and local pane URL into the
generated runtime copy. Local acceptance does not require editing either
tracked manifest.

The approved stable GUID must be incorporated separately into the normal
`InsightFlow.addin.xml` distribution manifest before production distribution.
That production-manifest change is not part of local acceptance.

### Local HTTPS hosting and network-share sideloading

Use the generated runtime manifest at:

```text
%LOCALAPPDATA%\InsightFlow\ExcelV2\OfficeAddins\InsightFlow.localtest.addin.xml
```

For the add-in-only XML manifest, use Microsoft's Windows network-share catalog
method:

1. Create a local folder such as `C:\OfficeAddins` and share it as
   `\\localhost\InsightFlowAddins`.
2. Register that share as a trusted Office catalog under
   `HKCU\Software\Microsoft\Office\16.0\WEF\TrustedCatalogs\{catalog-guid}`.
   Set `Id` to the catalog GUID, `Url` to `\\localhost\InsightFlowAddins`, and
   `Flags` to DWORD `1`. The catalog GUID is separate from the add-in's `<Id>`.
3. Copy only the generated runtime manifest from
   `%LOCALAPPDATA%\InsightFlow\ExcelV2\OfficeAddins\InsightFlow.localtest.addin.xml`
   into the shared folder. Never copy the tracked template directly.
4. Close all Office applications, reopen Excel, then choose **Home > Add-ins >
   Advanced > Shared Folder** and add InsightFlow.
5. If Excel or WebView2 prompts for localhost loopback access, allow it for the
   local test environment.

Network-share sideloading is for Windows testing, not production distribution.

### Local Windows acceptance sequence

Record the exact commit, Excel build/channel, Edge WebView2 version, browser,
runtime manifest path, approved GUID, and evidence for every case:

1. Open the workbook and confirm the localhost task pane loads over HTTPS.
2. Complete email/password login and verify the authenticated Excel identity.
3. Complete Google OAuth, verify the browser-to-Excel return flow, and confirm the authorization code is removed from the browser address bar.
4. Restore an existing Excel session and verify its identity.
5. Attempt login with the wrong browser account and confirm rejection.
6. Approve the exact displayed candidate identity and complete the one-time claim. Confirm the final authenticated UID matches the explicitly approved UID.
7. Reload the task pane during a pending handoff and verify safe behavior.
8. Close the browser before completion and verify retry, cancellation, and expiry. Confirm expired transactions cannot be claimed and staged ciphertext is cleared.
9. Cancel a pending handoff while the backend is unavailable and confirm local capabilities are cleared safely.
10. Log out locally, restart Excel, and verify session behavior. Confirm Excel-local logout does not sign out other InsightFlow clients.
11. Exercise the Office Dialog fallback where supported.

### Local shutdown and cleanup

Stop the backend and task-pane processes using the PIDs printed by the script.
Then remove the disposable database manually with `dropdb` as shown above.
Database cleanup is separate from process shutdown and is not performed
automatically by the preparation script.

## Production Windows Excel Desktop acceptance checklist

Use the real signed distribution manifest and deployed backend only after the
approved production migration, database target, role permissions, server
secrets, OAuth configuration, and deployment have been verified.

Production acceptance requires:

- An approved production database and migration plan.
- Verification that migration `0037` is present before `0038`.
- Verification of the actual production `DATABASE_URL` target and role.
- Verified grants, schema permissions, and RLS behavior.
- Approved production encryption, pairing, Supabase, and OAuth configuration.
- The stable owner-assigned GUID in the normal `InsightFlow.addin.xml`
  distribution manifest.
- The actual deployed backend and signed/approved distribution manifest.
- Real Windows Excel Desktop acceptance before release.

The production database blocker remains explicit. The connected Supabase project
migration history has no `0037_excel_auth_handoff.sql` record and no
`excel_handoff` schema. The Render workspace has no managed PostgreSQL
instance, so the actual Render runtime `DATABASE_URL` target and role remain
unverified. Do not apply production migrations or change Render configuration
until the target, migration history, roles, grants, RLS behavior, and production
secrets are independently verified and approved.

The normal distribution manifest is separate from the generated local runtime
manifest. Local acceptance must not modify either tracked manifest.

Post-deployment Windows acceptance must include:

1. Restore an existing session and verify the authoritative user identity.
2. Complete email/password login.
3. Complete Google OAuth.
4. Verify wrong-account rejection, explicit approval, and final identity
   verification.
5. Verify pending-handoff recovery, expiry, and cancellation.
6. Verify logout and session isolation from other clients.
7. Exercise the Office Dialog fallback where supported.

Automated CI is not a substitute for real Windows Excel Desktop acceptance.
