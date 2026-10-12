# Organization Bootstrap: Supabase Auth + PostgreSQL

The active application bootstrap path is Supabase Auth plus the PostgreSQL authorization provider. Firebase Auth, Firebase Admin credentials, and Realtime Database are not valid bootstrap dependencies.

## Preconditions

The trusted backend must have:

- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY` (backend-only, when required by invitation/auth administration)
- `DATABASE_URL` pointing to the intended PostgreSQL database
- `AUTHZ_PERSISTENCE_PROVIDER=supabase`

Never place service-role/secret keys in Flutter, browser JavaScript, source control, issues, or pull requests.

## Registration flow

Use `POST /v1/authz/organizations/register` with a valid, email-verified Supabase Auth bearer token and the required organization, branch, contact, address, and identity-profile fields.

The backend verifies the Supabase token and creates the organization, branch/workspace, principal identity binding, membership, role assignment, profile, and initial audit state in the PostgreSQL transaction. Organization/workspace IDs, principal IDs, employee IDs, and authorization assignments are server-generated; client-supplied identity, role, or workspace overrides are rejected.

The current provider initializes the first branch membership as `branch_head`. Do not treat this endpoint as proof that a separate Organization Owner hierarchy is implemented; that role-layer contract requires its own explicit verification.

## Transaction and retry behavior

- Registration is executed through the PostgreSQL provider.
- The identity binding and active membership are checked within the registration transaction.
- A repeated registration cannot silently create a second active organization membership for the same Supabase subject.
- Database errors must fail the request; no RTDB fallback is allowed.
- Concurrency and rollback guarantees are validated in the isolated PostgreSQL integration suite.

## Last-owner and role changes

Role mutation and membership status changes must use the PostgreSQL provider's last-owner guard and transaction. Never change role, membership, branch, or resource grants directly from Flutter or by editing database records manually.

## Production safety

This repository work does not initialize production organizations, apply production migrations, change secrets, or deploy to Render. Before any production rollout, review and approve the pending schema migrations and the historical-data import plan separately, then validate against a non-production Supabase project first.
