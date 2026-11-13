# InsightFlow Universal Identity

## Goal

Use one InsightFlow identity across Web, Excel, Android, iOS, Windows, and macOS while maintaining separate, revocable sessions for each app installation. Authentication identifies the user; InsightFlow authorization continues to decide which organization, branch, role, dataset, and operation that user may access.

## Current repository implementation

The current production authentication path uses Supabase Auth directly in each client:

- Flutter Web, mobile, and desktop use the configured Supabase Auth client.
- The Flutter client persists and refreshes its own session.
- Browser and native clients use Authorization Code with PKCE.
- Local sign-out, sign out other sessions, and global sign-out are explicit Supabase scopes.
- FastAPI verifies Supabase access tokens and applies the existing organization, branch, role, and dataset authorization model.

This provides a shared account system and flexible multi-device sessions. It does **not** by itself provide silent cross-application SSO: an Excel WebView, an independent browser profile, and a native app do not automatically share each other's local token storage.

## Target architecture for full SSO

Use Supabase Auth as the identity provider and its OAuth 2.1 / OpenID Connect server as the authorization server for first-party InsightFlow clients.

Proposed public OAuth clients:

| Client ID | Client |
| --- | --- |
| `insightflow-web` | InsightFlow Web |
| `insightflow-excel` | Excel Add-in |
| `insightflow-mobile` | Android and iOS |
| `insightflow-desktop` | Windows and macOS |

All clients must use Authorization Code with PKCE. Native clients must use the system browser and registered application-link / deep-link callbacks. Public clients must not contain client secrets. Each client must retain its own refresh token in its platform's approved storage.

### Required Supabase project configuration

The OAuth 2.1 Server is a hosted Supabase Auth capability. Enabling it is a project-level action, not a GitHub source-code change.

1. In Supabase Dashboard, open **Authentication → OAuth Server** and enable the OAuth 2.1 server.
2. Configure the authorization URL path and a dedicated InsightFlow consent UI.
3. Register each first-party client with exact redirect URIs and PKCE enabled.
4. Request only the OIDC scopes required by InsightFlow, such as `openid`, `email`, and `profile`.
5. Configure asymmetric JWT signing before requesting OIDC ID tokens.
6. Test authorization-code exchange, refresh-token rotation, logout, account recovery, and client revocation in a non-production project first.

Official setup: https://supabase.com/docs/guides/auth/oauth-server/getting-started

The Supabase OAuth 2.1 Server is currently documented as beta. Keep the existing Supabase Auth login path available until the hosted feature, consent UI, client registrations, and every platform callback have been validated. Do not enable a production migration merely by setting client-side environment variables.

## Excel Add-in and Microsoft identity

The Excel Add-in is a separate security boundary even when its UI is the Flutter Web application. For Microsoft work/school identity, Microsoft Nested App Authentication (NAA) can provide SSO in supported Office hosts after a Microsoft Entra app registration and Office manifest configuration. NAA's Microsoft token is not an InsightFlow Supabase token; it must not be sent to FastAPI as an InsightFlow bearer token. Use it only as an identity-provider hand-off if the product explicitly supports Entra federation.

Microsoft guidance: https://learn.microsoft.com/en-us/office/dev/add-ins/develop/enable-nested-app-authentication-in-your-add-in

## Authorization invariants

- The verified Supabase user UUID is the stable identity key.
- OAuth `client_id` identifies the requesting application; it is not a role or permission.
- Never grant organization, branch, or dataset access from client-supplied metadata.
- FastAPI remains the authorization gateway for protected InsightFlow APIs.
- Existing Supabase RLS and server-side role/branch checks remain authoritative.
- Never ship Supabase service-role or secret keys in browser, Excel, Flutter mobile, or desktop packages.
- A global logout revokes refresh sessions, but already-issued access JWTs may remain valid until expiry. Keep access-token lifetimes short and consider authoritative session checks on sensitive operations.

## Production readiness gate

Full Universal Identity SSO is not complete until all of the following have been verified:

- OAuth Server is enabled in the intended Supabase project.
- The central consent UI is deployed and handles approval/denial safely.
- Web, Excel, mobile, and desktop clients are registered and pass PKCE callback tests.
- Silent authentication works only where a compatible browser/OS authentication context exists; cross-device authentication still requires an active identity-provider session.
- Each client stores its own refresh token securely.
- Local, other-session, and global logout behavior passes integration tests.
- FastAPI and Supabase RLS continue enforcing the same organization, branch, and dataset permissions.
- Production rollback to the existing login path has been tested.

Until then, describe the current release as **shared Supabase identity with flexible multi-device sessions**, not as fully deployed cross-platform silent SSO.
