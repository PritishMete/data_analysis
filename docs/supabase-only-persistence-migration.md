# Supabase-only authorization persistence migration checklist

This is a source-level audit ledger for PR #13. A checked item means the specific
operation is routed to PostgreSQL in the current working branch; it does not
mean the complete RTDB migration is finished. Legacy RTDB code remains in
`firebase_authz/service.py`, so this migration must stay Draft.

| Operation | Current caller / legacy path | PostgreSQL implementation | Status / remaining validation |
|---|---|---|---|
| Token verification and stable identity | `service.verify_id_token`, auth middleware | `supabase_auth.verify_supabase_access_token` | Supabase-only token verification exists; needs invalid/expired/algorithm/signature and Firebase-token rejection tests. |
| Principal and identity lookup | `service.resolve_principal`, `service._user` | `supabase_provider._identity`, `_principal_for_claims`, `authorization_context` | Supabase subject is now the only provider key in the PostgreSQL provider; old RTDB resolver remains in source and must be removed after caller migration. |
| Organization / workspace bootstrap | `service.bootstrap_owner`, route fallback | `supabase_provider.register_organization` transaction | PostgreSQL implementation exists; concurrency and rollback integration tests still required. |
| Branches, locations, sections, assignments | `management_domain.py` SQL operations; legacy workspace records in service | PostgreSQL tables `locations`, `sections`, `organizational_assignments` | Management domain is PostgreSQL-backed; audit all external callers and enforce scope in DB-backed tests. |
| Membership and employee assignment | RTDB `workspaces/*/members` | `organization_members`, `organizational_assignments`, `member_roles` | Provider operations exist; remove direct RTDB code and test suspend/remove/revoke and cross-branch isolation. |
| Roles and permissions | RTDB role maps and service mutations | `roles`, `permissions`, `role_permissions`, `member_roles` | Provider mutations exist; test escalation denial and last-owner guard under concurrent changes. |
| Resource and dataset grants | RTDB grants/dataset maps | `authorization_resources`, `resource_grants`, `dataset_authorization` | Provider operations exist; DB-backed owner/scope/grant revocation tests still required. |
| Invitation create / pending list | RTDB invitation records in service | `invitations`, `supabase_provider.create_invitation`, `pending_invitations` | PostgreSQL paths exist; verify no early Auth user creation, expiry, resend, and delivery contract. |
| Invitation acceptance | RTDB invitation/member writes | `supabase_provider.accept_invitation` with row lock and transaction | PostgreSQL transaction exists; concurrent acceptance and rollback tests still required. |
| Invitation password setup / replay / revoke | RTDB invitation status updates | `mark_invitation_password_setup`, invitation status fields | Partial lifecycle exists; verify secure token binding, revocation and replay handling end-to-end. |
| Suspension and account removal | RTDB member/user status plus token revocation | `set_membership_status`, `cleanup_account` transactions | PostgreSQL implementation exists; test immediate access denial and last-owner protection. |
| Audit events | RTDB `audit/*` in legacy service | `audit_events`, `audit_dataset_event` | PostgreSQL audit path now uses Supabase subject; remove RTDB writer and test audit transaction failures. |
| Employee ID allocation | RTDB counter transaction | `organization_employee_id_counters`, `_allocate_employee_id` | PostgreSQL row-locked allocator exists; concurrent allocation test still required. |
| Profiles and duplicate identity fields | profile domain and prior uniqueness migrations | `organization_member_profiles`, migration `0026_member_identity_uniqueness.sql` | Existing PostgreSQL constraints/tests exist; test concurrency and normalization against isolated PostgreSQL. |
| Management Cell / `/v1/authz/me` | route provider selector and legacy service | `authorization_context`, `management_snapshot`, management domain | Routes default to PostgreSQL and fail closed for legacy provider configuration; verify every endpoint and first-screen contract. |
| Middleware protected routes | legacy `service.authorization` fallback | `supabase_provider.authorize` | Legacy fallback now fails closed; comprehensive protected-route integration tests still required. |

## Remaining validation before completion

- The active application no longer imports the legacy RTDB service. `firebase_authz/service.py` is now a compatibility export module for Supabase auth/error helpers; the old RTDB implementation and emulator tests have been removed from the application/test discovery path.
- The active Auth-user cleanup trigger is replaced by migration `0032_supabase_only_auth_user_cleanup.sql`, which resolves only `provider='supabase'` and the Supabase Auth UUID. Earlier migrations retain historical Firebase references because migration history is immutable.
- The PostgreSQL integration job now creates a disposable Supabase-compatible schema surface, applies the repository migrations, and runs `tests/test_supabase_provider.py` and `tests/test_management_domain.py`. This validates database transactions and schema on an isolated PostgreSQL service, not a production database.
- Full acceptance still depends on the final GitHub Actions run passing, and on additional concurrency/security tests covering concurrent invitation acceptance and employee-ID allocation, invalid JWT algorithms/signatures, role escalation, and all requested invitation replay/revocation edge cases.
- Historical-data migration/import is not executed by this branch. If production RTDB contains required legacy authorization records, a separately reviewed, idempotent export/import and reconciliation plan is required before any production rollout.

No production database was connected to or changed as part of this work. No production secrets were changed and no Render deployment was triggered.
