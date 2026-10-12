# Supabase-only authorization persistence migration checklist

This document records the active runtime path on `fix/supabase-only-auth-20261012`. It is an audit checklist, not a declaration that the migration is complete. Keep PR #13 in Draft until every item and required CI job passes.

## Operation-by-operation trace

| Operation | Active caller | PostgreSQL replacement | Transaction / concurrency requirement | Regression coverage |
|---|---|---|---|---|
| Bearer token verification and stable identity | `firebase_authz.auth.verify_id_token`; `firebase_authz.middleware`; authz and dataset routes | Supabase JWT/JWKS validation in `firebase_authz.supabase_auth`; UUID subject in `identity_bindings(provider='supabase', provider_subject)` | Verify signature, issuer, audience, expiry and confirmed email before protected access; no alternate-provider fallback | `tests/test_supabase_auth.py`, `tests/test_supabase_only_auth.py`, `tests/test_supabase_authz_api.py` |
| User/principal lookup | `supabase_provider._identity`, `_principal_for_claims`, `_principal_for_uid` | `principals`, `identity_bindings`, `organization_members` | Lock identity/member rows during invitation acceptance, role mutation and cleanup | `tests/test_supabase_provider.py`, `tests/test_supabase_only_persistence.py` |
| Organization bootstrap | `POST /v1/authz/organizations/register` → `supabase_provider.register_organization` | `organizations`, `workspaces`, `locations`, `principals`, `identity_bindings`, `organization_members`, `member_roles`, `organizational_assignments`, profile and audit tables | Single database transaction; transaction-scoped advisory lock by Supabase subject; unique constraints for identity/profile/branch invariants | `test_supabase_registration_rolls_back_when_final_registration_stage_fails`, `test_concurrent_organization_bootstrap_does_not_duplicate_membership` |
| Branch/location creation and branch scope | Management endpoints → `management_domain.create_location`, `list_locations`, `_management_scope` | `locations`, `organizational_assignments`, `member_roles`, `role_permissions`, audit events | Enforce organization-owner vs branch-head scope in the database-backed domain; reject cross-organization IDs | `tests/test_management_domain.py` |
| Membership and employee assignment | Invitation acceptance, membership status, approved employee, delegation | `organization_members`, `organizational_assignments`, `approved_employees`, `delegations` | Row-lock invitations and target memberships; transactionally create/update membership and role/assignment state | `tests/test_supabase_provider.py`, `tests/test_management_domain.py` |
| Roles and permissions | `/roles`, `/roles/mutate`, authorization checks and management domain | `roles`, `permissions`, `role_permissions`, `member_roles` | Server-side actor/target scope checks; lock owner membership for last-owner protection; no client-selected authority | `tests/test_supabase_provider.py`, `tests/test_supabase_authz_api.py` |
| Resource grants | `/resource-grants` → `supabase_provider.set_resource_grant` | `resource_grants` / `authorization_resources` and audit records | Verify grantor permission and target organization in one transaction | `tests/test_supabase_provider.py`, `tests/test_supabase_only_persistence.py` |
| Dataset registration, grants and working copies | Dataset authz routes → `supabase_provider.register_dataset`, `set_dataset_grant`, `create_working_copy`, `authorize_dataset`, `authorize_working_copy` | `dataset_authorization`, `dataset_grants`, `working_copy_authorization`, `working_copy_assignments`, dataset storage tables | Enforce organization and branch/location scope on each operation; transactionally revoke dependent copies/grants | `tests/test_supabase_provider.py`, managed-dataset and middleware tests |
| Invitation creation, resend, acceptance, expiry and revocation | `/invitations*` → `supabase_provider.create_invitation`, `pending_invitations`, `accept_invitation`, `mark_invitation_password_setup` | `invitations`, `identity_bindings`, `organization_members`, `member_roles`, `organizational_assignments` | Lock invitation row with `FOR UPDATE`; validate recipient, organization, status and expiry; atomically accept and create membership/role/assignment; email transport stays outside authorization | `tests/test_supabase_provider.py`, `tests/test_employee_invitation_flow.py`, `tests/test_employee_invitation_admin.py` |
| Suspension, removal and access revocation | `/membership/status`, account cleanup and authorization context | Membership status, identity binding status, roles/assignments/grants, audit records | Mutate status and related access records in one transaction; protected reads re-check current database state | `tests/test_supabase_provider.py`, `tests/test_supabase_authz_api.py` |
| Audit events | Registration, management, role/grant and dataset mutation code | `audit_events` and dataset audit tables | Write audit record in the same transaction as the corresponding mutation when required | `tests/test_supabase_provider.py`, `tests/test_management_domain.py` |
| Employee ID allocation | Registration and invitation acceptance → `_allocate_employee_id` | `organization_employee_id_counters` | Atomic `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`; transactionally bind allocated ID to the member | `test_concurrent_employee_id_allocation_is_unique`, invitation acceptance tests |
| `/v1/authz/me` and Management Cell context | `firebase_authz.routes.me`, `/management`, `/membership` | `supabase_provider.authorization_context`, `management_snapshot` and management-domain queries | Recompute role, membership status, workspace and scope from PostgreSQL on each request; client metadata is not authoritative | `tests/test_supabase_authz_api.py`, `tests/test_supabase_provider.py`, Flutter Management Cell contract tests |
| Account deletion cleanup | Auth-user cleanup trigger migration and backend cleanup endpoint | `0032_supabase_only_auth_user_cleanup.sql`; identity binding by Supabase UUID only | PostgreSQL trigger/transaction cleans related authorization records; do not consult historical Firebase UID columns | `tests/test_supabase_only_persistence.py` |

## Schema and migration notes

- Runtime authorization state is intended to be stored in PostgreSQL; application authentication is Supabase Auth.
- `firebase_authz/service.py` is now a compatibility export module for shared Supabase auth/error primitives. Active routes and middleware call Supabase/PostgreSQL implementations; the retired RTDB service and emulator test were removed from runtime/test discovery.
- `migrations/0032_supabase_only_auth_user_cleanup.sql` replaces the active auth-user cleanup function without resolving principals through legacy Firebase UID values.
- `migrations/0033_manager_scoped_users_manage.sql` adds the scoped Manager capability required by branch-management operations; the management domain still checks the Manager's active branch assignment before each mutation.
- Earlier migration files that mention Firebase are historical migration records and must not be used as a runtime fallback.
- CI uses a disposable PostgreSQL service and `tests/sql/supabase_compat.sql` to model the Supabase-managed `auth`/`storage` surfaces needed by schema tests. No production credentials or production database are used.
- Do not apply migrations to production as part of this PR. Any historical data import requires a separately reviewed, idempotent plan after its source format has been verified.

## Completion gates

- [ ] Static guard finds no active Firebase Auth or RTDB code/configuration.
- [ ] Schema migrations apply cleanly to an empty disposable PostgreSQL database.
- [ ] PostgreSQL-backed authorization, invitation, scope, concurrency and rollback tests pass.
- [ ] Protected-path tests run with authentication required.
- [ ] Flutter analysis, tests and web build pass without Firebase Auth dependencies.
- [ ] Full backend regression suite passes; stale tests are repaired rather than weakening authorization.
- [ ] Final PR diff and final workflow run are reviewed. PR remains Draft until all gates pass.

No production database was connected to or changed as part of this work. No production secrets were changed and no Render deployment was triggered.
