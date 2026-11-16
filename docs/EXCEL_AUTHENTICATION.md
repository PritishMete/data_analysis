# Excel add-in authentication

InsightFlow's Excel task pane uses the same Supabase Auth identity as the website and other clients. It does not read Chrome cookies or copy credentials from another browser profile.

## Runtime flow

1. Office.js resolves the Office host before Flutter starts.
2. The task pane restores and validates its own persisted Supabase session.
3. A valid session opens the authenticated InsightFlow workspace without another login.
4. If no valid session exists, the task pane opens an Office Dialog API window on the same HTTPS origin.
5. The dialog hosts the normal InsightFlow sign-in UI. Email/password and configured Supabase OAuth providers use the existing Supabase PKCE flow.
6. After Supabase confirms the user, the dialog sends a versioned authentication message to the task pane using `Office.context.ui.messageParent`.
7. The task pane consumes the one-time refresh token with `supabase.auth.setSession`, validates the user with Supabase Auth, and lets the normal AuthGate open the workspace.

The refresh token is never placed in a URL or written to application logs. Supabase refresh-token rotation means the task pane obtains its own refreshed session. The dialog closes after the handoff.

## Website behavior

The dialog route is selected only by the `excelAuthDialog=1` query flag. A normal website visit continues through the existing AuthGate and opens the normal management/workspace landing page. The Excel callback flag is restored across the Supabase OAuth redirect using dialog-scoped session storage.

## Office hosting requirements

- The add-in task pane must be served over HTTPS.
- The first URL passed to `displayDialogAsync` must use the exact same origin as the task pane.
- Keep the deployed add-in manifest's task-pane URL on the GitHub Pages origin used by InsightFlow.
- Do not use `displayInIframe: true` for authentication. Identity-provider sign-in pages may block iframe embedding.
- The Office dialog API is used instead of `window.open`, which is unreliable in Office webviews.

The dialog is a separate Office-managed browser/webview context. It does not gain access to a user's private Chrome profile or its cookies. A user who already has a valid Excel task-pane session will not see the dialog; a user with only a Chrome website session may need to authenticate in the Office dialog once.

## Build and test

The GitHub Pages workflow runs:

- `node test/excel_auth_bridge_test.js`
- Auth/onboarding Flutter regression tests
- Flutter analysis for the Excel auth gate and JS interop
- The production Flutter web build and Pages deployment

## Manual Excel verification

1. Open the add-in in Excel with an existing valid task-pane session. Confirm the workspace opens directly.
2. Clear the add-in's site data/session and reopen it. Confirm Excel shows the sign-in check and opens the Office sign-in dialog.
3. Sign in with email/password. Confirm the dialog reports success, closes, and the task pane opens the workspace.
4. Repeat with the configured Google OAuth provider. Confirm the callback returns to the dialog and completes the handoff.
5. Close and reopen Excel. Confirm the saved task-pane session is restored.
6. Sign out locally and reopen the add-in. Confirm it asks for sign-in again.
7. Open the website directly in Chrome. Confirm website login still opens the normal management page and does not trigger Excel routing.
