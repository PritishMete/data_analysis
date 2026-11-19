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

## Windows Excel Desktop test build (local-only)

This procedure uses a disposable local PostgreSQL database and a locally running backend. It does not require a Render deployment or production database migration. Do not point the test build at the current Render backend yet: the Render service still tracks `main`, while the v2 API is only in this pull request.

### Required local tools

- Windows 11, Microsoft Excel Desktop (Microsoft 365), and Edge WebView2
- Flutter stable (matching the repository's Dart SDK constraint), Python, Node.js/npm
- PostgreSQL 16 with `psql`, and the repository's Python requirements
- `mkcert` to create a locally trusted HTTPS certificate

### 1. Prepare a disposable database and backend

From the repository root, create a new empty local database (do not reuse a production database). Apply the migrations in order:

```powershell
psql "postgresql://postgres:<LOCAL_PASSWORD>@127.0.0.1:5432/insightflow_excel_test" -v ON_ERROR_STOP=1 -f migrations/0037_excel_auth_handoff.sql
psql "postgresql://postgres:<LOCAL_PASSWORD>@127.0.0.1:5432/insightflow_excel_test" -v ON_ERROR_STOP=1 -f migrations/0038_excel_auth_pairing.sql
```

Set backend configuration in the same PowerShell window. Generate fresh local-only secrets; do not reuse production values:

```powershell
$env:DATABASE_URL = "postgresql+psycopg://postgres:<LOCAL_PASSWORD>@127.0.0.1:5432/insightflow_excel_test"
$env:INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY = python -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())"
$env:INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY = python -c "import secrets; print(secrets.token_urlsafe(32))"
$env:SUPABASE_URL = "https://<PROJECT_REF>.supabase.co"
$env:SUPABASE_PUBLISHABLE_KEY = "<SUPABASE_PUBLISHABLE_KEY>"
```

`SUPABASE_AUTH_ISSUER` is optional and defaults to `<SUPABASE_URL>/auth/v1`. `SUPABASE_AUTH_AUDIENCE` is optional and defaults to `authenticated`. The backend requires `DATABASE_URL` to resolve to PostgreSQL. Do not set a Supabase service-role key for this flow.

Create and trust a localhost certificate, then start the backend with HTTPS:

```powershell
mkcert -install
mkcert localhost 127.0.0.1 ::1
uvicorn main:app --host 127.0.0.1 --port 8000 --ssl-certfile localhost+2.pem --ssl-keyfile localhost+2-key.pem
```

Run the backend from the repository root. Confirm `https://localhost:8000/health` responds before building the task pane.

### 2. Build the Flutter task pane

In a second PowerShell window:

```powershell
cd apps/flutter_app
flutter pub get
flutter build web --release --base-href / `
  --dart-define=INSIGHTFLOW_BACKEND_URL=https://localhost:8000 `
  --dart-define=INSIGHTFLOW_SUPABASE_URL=https://<PROJECT_REF>.supabase.co `
  --dart-define=INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY=<SUPABASE_PUBLISHABLE_KEY> `
  --dart-define=INSIGHTFLOW_AUTH_REDIRECT_URL=https://localhost:3000/
```

Serve `apps/flutter_app/build/web` over HTTPS. From that directory, or by supplying its path:

```powershell
npx --yes http-server build/web -a 127.0.0.1 -p 3000 -S -C ..\..\localhost+2.pem -K ..\..\localhost+2-key.pem
```

The certificate must be trusted by Windows and include `localhost`. Office add-ins should use HTTPS even during local development.

### 3. Create a temporary local manifest

Copy, do not overwrite, `apps/flutter_app/excel/InsightFlow.addin.xml`. In the temporary copy only:
- Change the `DefaultSettings/SourceLocation` from the GitHub Pages URL to `https://localhost:3000/`.
- Add `https://localhost:3000` as an `AppDomain`.
- Leave the existing icon and support URLs unchanged.

The checked-in manifest remains configured for GitHub Pages. The current `<Id>` is a syntactically formatted placeholder, not an owner-confirmed add-in identity. Before sideloading, the owner must confirm or generate one stable, unique add-in GUID and use it consistently in the test and future distribution manifests. Do not generate a production identity by guessing.

### 4. Sideload into Windows Excel Desktop

For the add-in-only XML manifest, use Microsoft's Windows network-share catalog method:

1. Create a local folder such as `C:\OfficeAddins` and share it as `\\localhost\InsightFlowAddins`.
2. Add that share as a trusted Office catalog under `HKCU\Software\Microsoft\Office\16.0\WEF\TrustedCatalogs\{catalog-guid}`. Set `Id` to the same catalog GUID, `Url` to `\\localhost\InsightFlowAddins`, and `Flags` to DWORD `1`. The catalog GUID is separate from the add-in's `<Id>`.
3. Copy the temporary local manifest into the shared folder.
4. Close all Office applications, reopen Excel, then choose **Home > Add-ins > Advanced > Shared Folder** and add InsightFlow.
5. If Excel/WebView2 prompts for localhost loopback access, allow it for the local test environment.

Network-share sideloading is for Windows testing, not production distribution.

### 5. Configure authentication redirects

Use a dedicated development Supabase project if available. In Supabase Auth URL Configuration, add the exact local app redirect `https://localhost:3000/` (or the narrowly scoped `https://localhost:3000/**` pattern). Keep the production Site URL unchanged.

For Google OAuth, the Google Cloud Web OAuth client needs the local app origin `https://localhost:3000` under Authorized JavaScript origins. Its Authorized redirect URI remains the Supabase provider callback URL shown in the Supabase Google provider settings, normally `https://<PROJECT_REF>.supabase.co/auth/v1/callback`; it is not the task-pane URL. Enable Google in the Supabase provider settings and use the matching client ID/secret there. Do not change production OAuth settings without owner approval.

### 6. Windows acceptance sequence

Record the Windows version, Excel build/channel, Edge WebView2 version, manifest GUID, browser, backend commit and test result for each case:

1. Open the workbook and confirm the task pane loads over HTTPS.
2. Restore a valid existing session and confirm the authoritative user check succeeds.
3. Sign out locally, then complete email/password browser login and approve the exact displayed account in Excel.
4. Repeat with Google OAuth; confirm the same browser tab returns to the task pane callback and the authorization code is removed from the address bar.
5. Sign in with the wrong account, reject it in Excel and confirm no session is established.
6. Reload the task pane while a handoff is pending; verify recovery without a second claim.
7. Close the browser before completion; retry with a fresh pairing code and verify the old capability is rejected.
8. Let a handoff expire and verify it cannot be claimed.
9. Cancel a pending handoff while offline or with the backend unavailable; confirm local Excel capabilities are cleared, then verify the server-side transaction expires and cannot be claimed.
10. Sign out from Excel, close Excel completely, reopen the workbook and verify the local session is gone while sessions in other clients remain active.
11. Repeat the supported path using the Office Dialog fallback.

Automated CI is not a substitute for this Windows Excel Desktop acceptance. The production backend remains on `main` until a separately approved deployment, so this local test backend is required for v2 acceptance before release.
