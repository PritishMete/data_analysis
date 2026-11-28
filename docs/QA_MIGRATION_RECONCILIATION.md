# QA migration reconciliation

The migration runner's normal production path is unchanged. QA operators must
first obtain sanitized, read-only history evidence and run:

```text
python tools/run_authz_migrations.py --dry-run-history tests/fixtures/qa_migration_history.json
```

The dry run performs no database connection, DDL, DML, history write, or object
creation. It reports repository identities, duplicate prefixes, external
mappings, pending migrations, blocked migrations, and the proposed order.
The fixture must identify the pinned QA project and database host; production
targets are rejected before reconciliation.
The result includes `plan_executable`. If it is false, the proposed execution
order is intentionally empty, even when pending migrations are listed.
Dependency cycles and unknown prerequisite identifiers are rejected.

`excel_auth_handoff_0037` is mapped to repository
`0037_excel_auth_handoff` and is excluded from replay. The external
`excel_auth_pairing_0038` migration is deliberately not mapped to repository
`0038_supabase_function_privilege_hardening`; repository 0038 remains distinct
and pending until its function prerequisites and SQL are reviewed.

An operator must review every blocked item and the complete proposed order,
compare the QA catalog with the migration SQL, and obtain explicit owner
approval before invoking the normal migration path. The fixture is synthetic
documentation only and must not be treated as live database evidence. A
`prerequisites` object may contain only boolean operator-supplied evidence for
known requirements such as `storage:managed-datasets` and
`key:INSIGHTFLOW_PROFILE_PII_KEY`; missing or false evidence blocks execution.
