# InsightFlow multi-device session policy

InsightFlow uses Supabase Auth as its identity authority. Each installation, browser profile, and Office Add-in host maintains its own secure Supabase session and refresh-token lifecycle. Sessions are not copied between applications.

## Required hosted Supabase setting

Repository code cannot override the hosted Supabase session-count policy. In the Supabase Dashboard for the project used by InsightFlow:

1. Open **Authentication → Sessions** (under Auth settings).
2. Turn **Single session per user** **off**. When enabled, Supabase keeps the most recently active session and terminates the other sessions as they refresh.
3. Leave **Time-box user sessions** and **Inactivity timeout** unset unless a deliberate session-expiry policy is wanted.
4. Save the settings.

Keep access tokens short-lived (the usual one-hour default is appropriate for most applications). Automatic refresh should keep a valid login active; do not lengthen the access-token lifetime to simulate persistent login.

## Session controls in InsightFlow

The account security screen exposes three explicit actions:

- **Sign out on this device** uses Supabase `local` scope and ends only this app installation's session.
- **End other sessions** uses Supabase `others` scope and keeps the current session active.
- **Sign out everywhere** uses Supabase `global` scope and revokes all refresh sessions for the account.

The scopes are always passed explicitly. This avoids relying on different SDK defaults across JavaScript and Flutter clients.

## Expected behavior

- Signing in on a desktop browser and a phone creates independent sessions; both can remain usable.
- Signing in later on another device does not sign out the first device when the hosted single-session setting is disabled.
- Signing out locally does not sign out other devices.
- Ending other sessions keeps the current device signed in.
- Global sign-out revokes all active refresh sessions and requires the user to authenticate again.
- Tabs sharing one browser profile may share a local browser session. This is not the same as a separate device session.

## Important token-revocation limitation

Supabase access tokens are signed JWTs. Revoking a session invalidates its refresh-token lifecycle, but an access token already issued for that session can remain valid until its expiry. Do not describe global logout as instant termination of every in-flight API request. Keep access tokens short-lived and use an authoritative active-session check for especially sensitive backend operations when immediate revocation is required.

## Verification checklist

1. Sign in to the web app on a desktop and confirm a protected page loads.
2. Sign in to the same account in the mobile app without signing out on desktop.
3. Use protected pages on both devices after the second login and after access-token refresh.
4. Use **End other sessions** on one device; confirm that device stays signed in and other devices are required to authenticate again.
5. Use **Sign out on this device**; confirm another active device remains signed in.
6. Use **Sign out everywhere**; confirm all clients are required to authenticate again after any already-issued access token expires.
7. Repeat with separate browser profiles to distinguish cross-device sessions from tabs sharing one browser session.

The automated Flutter contract test verifies PKCE configuration and the three configured logout scopes. The hosted Supabase setting and real cross-device behavior must still be verified in the actual project.
