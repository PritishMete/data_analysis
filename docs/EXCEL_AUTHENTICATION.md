# Excel add-in authentication

InsightFlow's Excel task pane uses the same Supabase Auth identity as the website and other clients. It does not read Chrome cookies or copy credentials from another browser profile.

## Runtime flow

1. Office.js resolves the Office host before Flutter starts.
2. The task pane restores and authoritatively validates its own persisted Supabase session.
3. If the task pane has no valid session, it creates a short-lived one-time handoff transaction through the existing backend /v1/excel-auth/handoff/create endpoint. The task-pane runtime retains the claim capability; the dialog receives only the transaction ID and completion capability.
4. The task pane opens an Office Dialog API window on the same HTTPS origin. A random 192-bit state nonce is included in the dialog URL and restored through dialog-scoped session storage after the Supabase OAuth redirect.
5. The dialog registers DialogParentMessageReceived and sends a state-bound ready message. The task pane validates the same origin and state before sending the handoff context through Dialog.messageChild. The context is sent again after OAuth redirects reload the dialog document. Capabilities are not placed in callback URLs or diagnostics.
6. The dialog hosts the normal InsightFlow sign-in UI. Email/password and configured Supabase OAuth providers use the existing Supabase PKCE flow.
7. After Supabase confirms the user, the dialog stops its automatic refresh timer and submits the authenticated access/refresh-token pair to the backend /complete endpoint over HTTPS. The backend validates the access-token identity, rotates the refresh token once with Supabase, verifies that the rotated identity matches, and encrypts the replacement token in the short-lived transaction.
8. The dialog marks its backend completion before sending a state- and transaction-bound completion notification through Office.context.ui.messageParent. The Office message contains no access token or refresh token. The dialog clears its local copy of the now-rotated session.
9. The task pane claims the encrypted replacement token once through /claim. The claim capability never leaves the task-pane runtime. It passes the returned rotated token to its own supabase.auth.setSession, which establishes an independently refreshed task-pane session.
10. The task pane authoritatively verifies its own session before opening the workspace. If another callback has already established a valid task-pane session, a late dialog result or close event cannot overwrite it or turn it into a sign-in error.
11. State, origin, transaction capability, three-minute expiry, encrypted storage, and atomic one-time claim checks are enforced throughout the flow. Duplicate completion requests are serialized by a database row lock so they cannot rotate the same submitted token twice.

The Supabase refresh token is never sent through messageParent, placed in a URL, or written to application diagnostics. The only refresh token returned to the task pane is the backend-rotated token from the one-time claim.


## Website behavior

The dialog route is selected only by the `excelAuthDialog=1` query flag. A normal website visit continues through the existing AuthGate and opens the normal management/workspace landing page. The Excel callback flag is restored across the Supabase OAuth redirect using dialog-scoped session storage.

## Office hosting requirements

- The add-in task pane must be served over HTTPS.
- The first URL passed to `displayDialogAsync` must use the exact same origin as the task pane.
- Keep the deployed add-in manifest's task-pane URL on the Cloudflare Pages origin used by InsightFlow.
- Do not use `displayInIframe: true` for authentication. Identity-provider sign-in pages may block iframe embedding.
- The Office dialog API is used instead of `window.open`, which is unreliable in Office webviews.

The dialog is a separate Office-managed browser/webview context. It does not gain access to a user's private Chrome profile or its cookies. A user who already has a valid Excel task-pane session will not see the dialog; a user with only a Chrome website session may need to authenticate in the Office dialog once.

## Manifest and registration

The add-in-only XML template is at
`apps/flutter_app/excel/InsightFlow.addin.xml`. It points to the deployed
Cloudflare Pages task pane and the deployed 192px/512px icon assets. Its GUID is a
clearly marked placeholder and must be replaced before organizational
deployment; the repository does not invent the tenant-owned add-in identity.

Before deployment, confirm the stable Add-in GUID, publisher details, icon
branding, and Microsoft 365 registration method. The task-pane URL is:
`https://insightflow-3e8.pages.dev/`.

## Build and test

The Flutter web publication workflow builds the app and updates the `gh-pages` source branch consumed by Cloudflare Pages. It runs:

- `node test/excel_auth_bridge_test.js`
- Auth/onboarding Flutter regression tests
- Flutter analysis for the Excel auth gate and JS interop
- The production Flutter web build and Cloudflare Pages source publication

## Manual Excel verification

1. Open the add-in in Excel with an existing valid task-pane session. Confirm the workspace opens directly.
2. Clear the add-in's site data/session and reopen it. Confirm Excel shows the sign-in check and opens the Office sign-in dialog.
3. Sign in with email/password. Confirm the dialog reports success, closes, and the task pane opens the workspace.
4. Repeat with the configured Google OAuth provider. Confirm the callback returns to the dialog and completes the handoff.
5. Close and reopen Excel. Confirm the saved task-pane session is restored.
6. Sign out locally and reopen the add-in. Confirm it asks for sign-in again.
7. Repeat Google OAuth after the dialog document reloads. Confirm the parent resends the state- and correlation-bound handoff context and the task pane claims the replacement token.
8. Confirm that repeated auth callbacks cannot complete or claim the transaction twice, and that a late dialog-close event does not replace a verified task-pane session.
9. Open the website directly in Chrome. Confirm website login still opens the normal management page and does not trigger Excel routing.
