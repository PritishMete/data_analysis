# Multi-device login

InsightFlow uses Supabase Auth for login. The Flutter client is configured to persist a session and automatically refresh its access token independently on each installation or browser profile. A normal sign-out explicitly uses Supabase's local scope; it must not revoke other devices' sessions.

## Required hosted Supabase setting

Repository code cannot override the hosted Supabase session-count policy. In the Supabase Dashboard for the project used by InsightFlow:

1. Open **Authentication → Sessions** (under Auth settings).
2. Turn **Single session per user** **off**. When enabled, Supabase keeps the most recently active session and terminates the other sessions as they refresh.
3. Leave the **Time-box user sessions** and **Inactivity timeout** unset unless a deliberate sign-out policy is wanted. These are separate from the single-session setting.
4. Save the settings.

The application's access token can still expire after its configured JWT lifetime. Automatic token refresh should keep a valid login active; do not lengthen the access-token lifetime merely to simulate persistent login.

## Expected behavior

- Signing in to InsightFlow on a desktop browser and a phone at the same time creates independent sessions; both remain usable.
- Signing in later on a second device does not sign out the first device.
- Signing out on a phone or on a desktop browser signs out that local session only. It does not sign out a different device.
- Tabs sharing the same browser profile may receive Supabase's same-browser session synchronization. That is different from a phone or a separate browser profile.
- Password changes, account/security actions, or membership/authorization revocation may legitimately require a session to reauthenticate or lose access.

## Verification checklist

1. Sign in to the web app on a desktop and confirm a protected page loads.
2. Sign in to the same account in the mobile app without signing out on desktop.
3. Use protected pages on both devices after the second login, and again after the access token refreshes.
4. Sign out on the phone; verify the desktop remains signed in.
5. Sign back in on the phone, then sign out on desktop; verify the phone remains signed in.
6. Repeat with separate desktop browser profiles to distinguish cross-device sessions from tabs sharing one local browser session.

The Flutter contract test covers client-side persistence, auto-refresh configuration, and local sign-out scope. The hosted Supabase setting and cross-device behavior must be verified separately in the real project.
