"""Read-only reconciliation for QA migration planning.

This module deliberately has no database dependency.  It reconciles the
repository manifest with sanitized, operator-supplied history evidence.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json


@dataclass(frozen=True)
class MigrationIdentity:
    version: str
    path: str
    kind: str = "repository"
    external_key: str | None = None


EXTERNAL_MAPPINGS = {
    "excel_auth_handoff_0037": "0037_excel_auth_handoff",
    "excel_auth_pairing_0038": None,
}

REVIEWED_ORDER = (
    "0001_authz_supabase", "0002_authz_security_and_seed", "0003_resource_grants",
    "0004_identity_firebase_uid_lookup", "0005_dataset_working_copy_authz",
    "0006_invitation_membership_role_metadata", "0007_approved_employees_delegations",
    "0008_organizational_structure", "0009_branch_head_role", "0010_branch_identifier",
    "0011_allow_unrestricted_branch_identifiers", "0011_branch_cleanup_triggers",
    "0012_auth_user_cascade_cleanup", "0013_managed_dataset_structured_storage",
    "0014_managed_dataset_security", "0014_mnc_data_invitation_roles",
    "0015_managed_dataset_grant_rls", "0016_managed_dataset_profiling_counts",
    "0017_managed_dataset_physical_tables", "0018_migrate_json_rows_to_physical_tables",
    "0019_organization_member_profiles", "0020_add_profile_geo_codes",
    "0021_organization_employee_id_counters", "0022_repair_invitation_auth_user_id",
    "0023_repair_invitation_delivery_metadata", "0024_invitation_branch_assignment",
    "0025_backfill_legacy_invitation_branch_assignments",
    "0026_role_hierarchy_and_working_copy_assignments", "0027_management_assignment_approval",
    "0028_role_capability_hardening", "0029_dataset_authorization_branch_scope",
    "0030_manager_dataset_upload_and_copy_grants", "0030_single_active_branch_assignment",
    "0031_remove_employee_role", "0031_restrict_manager_original_dataset_writes",
    "0032_preflight_existing_branch_assignment_conflicts", "0033_allow_multiple_managers_per_location",
    "0034_dataset_change_proposals", "0035_branch_scoped_manager_upload_grants",
    "0035_managed_dataset_integrity", "0036_management_permission_scope_hardening",
    "0037_excel_auth_handoff", "0038_supabase_function_privilege_hardening",
    "0039_encrypt_profile_pii", "0040_password_verification_attempt_protection",
    "0041_password_verification_rolling_window", "0042_diagnostic_admin",
    "0043_insightflow_company_admin", "0044_platform_backend_events",
    "0045_backend_error_stack",
)

DEPENDENCIES = {
    "0011_branch_cleanup_triggers": {"0010_branch_identifier"},
    "0012_auth_user_cascade_cleanup": {"0011_branch_cleanup_triggers"},
    "0014_managed_dataset_security": {"0013_managed_dataset_structured_storage", "storage:managed-datasets"},
    "0015_managed_dataset_grant_rls": {"0014_managed_dataset_security", "storage:managed-datasets"},
    "0038_supabase_function_privilege_hardening": {
        "0011_branch_cleanup_triggers", "0012_auth_user_cascade_cleanup",
        "0030_single_active_branch_assignment",
    },
    "0039_encrypt_profile_pii": {"0019_organization_member_profiles", "key:INSIGHTFLOW_PROFILE_PII_KEY"},
    "0043_insightflow_company_admin": {"0042_diagnostic_admin"},
    "0045_backend_error_stack": {"0044_platform_backend_events"},
}
KNOWN_PREREQUISITES = {item for values in DEPENDENCIES.values() for item in values if ":" in item}

QA_PROJECT_REF = "xcnjauxmofqkwnpdazpj"
PRODUCTION_PROJECT_REF = "zfdgwnipdyrpbardqoql"
QA_DATABASE_HOST = f"db.{QA_PROJECT_REF}.supabase.co"
PRODUCTION_DATABASE_HOST = f"db.{PRODUCTION_PROJECT_REF}.supabase.co"


def repository_manifest(directory: Path) -> list[MigrationIdentity]:
    paths = sorted(directory.glob("[0-9][0-9][0-9][0-9]_*.sql"), key=lambda p: p.name)
    identities = [MigrationIdentity(p.stem, p.as_posix()) for p in paths]
    return identities


def validate_dependency_graph(known: set[str], dependencies: dict[str, set[str]] | None = None) -> None:
    graph = dependencies or DEPENDENCIES
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(node: str) -> None:
        if node not in known:
            return
        if state.get(node) == 1:
            start = stack.index(node)
            cycle = stack[start:] + [node]
            raise ValueError("migration dependency cycle: " + " -> ".join(cycle))
        if state.get(node) == 2:
            return
        state[node] = 1
        stack.append(node)
        for dependency in sorted(graph.get(node, set())):
            if dependency in known:
                visit(dependency)
        stack.pop()
        state[node] = 2

    for node in sorted(known):
        visit(node)


def validate_manifest(repository: list[MigrationIdentity]) -> None:
    versions = [item.version for item in repository]
    if len(versions) != len(set(versions)):
        raise ValueError("repository manifest contains duplicate migration identities")
    if any(not Path(item.path).is_file() for item in repository):
        raise ValueError("repository manifest references a missing SQL file")
    known = set(versions)
    for migration, dependencies in DEPENDENCIES.items():
        if migration in known:
            bad = [d for d in dependencies if not (d in known or d.startswith(("key:", "storage:")))]
            if bad:
                raise ValueError(f"dependency manifest references unknown migration(s): {','.join(bad)}")
    if set(versions) != set(REVIEWED_ORDER):
        raise ValueError("repository manifest does not match the reviewed migration set")
    validate_dependency_graph(known)


def reconcile(repository: list[MigrationIdentity], external_history: list[str],
              prerequisites: dict[str, bool] | None = None) -> dict:
    validate_manifest(repository)
    prerequisites = prerequisites or {}
    repo_by_version = {m.version: m for m in repository}
    duplicate_prefixes: dict[str, list[str]] = {}
    for item in repository:
        duplicate_prefixes.setdefault(item.version[:4], []).append(item.version)
    duplicate_prefixes = {k: v for k, v in duplicate_prefixes.items() if len(v) > 1}

    mapped: dict[str, str | None] = {}
    blocked: list[dict[str, str]] = []
    duplicates = sorted({value for value in external_history if external_history.count(value) > 1})
    for external in duplicates:
        blocked.append({"migration": external, "reason": "duplicate external migration identity"})
    for external in external_history:
        if external not in EXTERNAL_MAPPINGS:
            blocked.append({"migration": external, "reason": "unknown external migration identity"})
            continue
        mapped[external] = EXTERNAL_MAPPINGS[external]

    represented = {value for value in mapped.values() if value}
    pending = [version for version in REVIEWED_ORDER if version in repo_by_version and version not in represented]
    status = set(represented)
    for version in pending:
        if prerequisites.get(version) is False:
            blocked.append({"migration": version, "reason": "prerequisite not verified"})
            continue
        for dependency in DEPENDENCIES.get(version, set()):
            if dependency.startswith(("key:", "storage:")) and prerequisites.get(dependency) is not True:
                blocked.append({"migration": version, "reason": f"prerequisite not verified: {dependency}"})
            elif dependency in pending and dependency not in status:
                blocked.append({"migration": version, "reason": f"dependency not executable: {dependency}"})
        if not any(item["migration"] == version for item in blocked):
            status.add(version)

    plan_executable = not blocked
    return {
        "external_history": external_history,
        "external_mappings": mapped,
        "repository_migrations": [m.version for m in repository],
        "duplicate_prefixes": duplicate_prefixes,
        "represented_repository_migrations": sorted(represented),
        "pending_migrations": pending,
        "blocked_migrations": blocked,
        "plan_executable": plan_executable,
        "proposed_execution_order": [v for v in REVIEWED_ORDER if plan_executable and v in pending and not any(
            b["migration"] == v for b in blocked
        )],
    }


def validate_fixture_target(payload: dict) -> None:
    target = payload.get("target")
    if not isinstance(target, dict):
        raise ValueError("fixture must declare a target")
    if target.get("project_ref") != QA_PROJECT_REF:
        raise ValueError("dry-run target is not the allowlisted QA project")
    if target.get("database_host") != QA_DATABASE_HOST:
        raise ValueError("dry-run target is not the allowlisted QA database")
    if target.get("project_ref") == PRODUCTION_PROJECT_REF or target.get("database_host") == PRODUCTION_DATABASE_HOST:
        raise ValueError("dry-run target is production")


def load_fixture(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    validate_fixture_target(payload)
    history = payload.get("external_history")
    if not isinstance(history, list) or not all(isinstance(v, str) for v in history):
        raise ValueError("fixture must contain external_history as a list of strings")
    prerequisites = payload.get("prerequisites", {})
    if not isinstance(prerequisites, dict):
        raise ValueError("fixture prerequisites must be an object")
    unknown = sorted(set(prerequisites) - KNOWN_PREREQUISITES - set(REVIEWED_ORDER))
    if unknown:
        raise ValueError("fixture contains unknown prerequisite(s): " + ",".join(unknown))
    if not all(isinstance(value, bool) for value in prerequisites.values()):
        raise ValueError("fixture prerequisites must contain boolean values")
    payload["prerequisites"] = prerequisites
    return payload
