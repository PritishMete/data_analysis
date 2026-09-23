from __future__ import annotations
import re

ACTIONS = frozenset({
    "data.view", "analysis.run", "worksheet.create", "pivot.create",
    "worksheet.modify", "worksheet.delete", "operation.undo.own",
    "operation.undo.other", "history.view", "users.manage", "roles.manage",
    "policies.manage",
    "organization.view", "organization.manage",
    "membership.view", "membership.manage",
    "dataset.view_original", "dataset.create_working_copy",
    "dataset.edit_working_copy", "dataset.delete", "dataset.share",
    "dataset.manage_acl",
    "working_copy.view", "working_copy.modify", "working_copy.delete",
    "audit.view", "invitation.manage", "delegation.manage",
    "account.delete", "excel.mutate.original", "excel.mutate.working_copy",
})

ROLE_ALIASES = {
    "owner": "organization_owner",
    "analyst": "employee",
    "viewer": "external_viewer",
}

ROLE_LEVELS = {
    "external_viewer": 10,
    "employee": 20,
    "team_lead": 30,
    "manager": 40,
    "organization_owner": 50,
}

DEFAULT_ROLES = {
    # Legacy role IDs remain valid for backward compatibility. Phase 4 maps
    # them into the organization RBAC roles without changing authentication.
    "owner": set(ACTIONS),
    "analyst": {"data.view","analysis.run","worksheet.create","pivot.create","worksheet.modify","operation.undo.own","history.view"},
    "viewer": {"data.view","history.view"},
    "organization_owner": set(ACTIONS),
    "manager": {
        "data.view","analysis.run","worksheet.create","pivot.create",
        "worksheet.modify","worksheet.delete","operation.undo.own",
        "history.view","users.manage","roles.manage","policies.manage",
        "organization.view","membership.view","membership.manage",
        "dataset.view_original","dataset.create_working_copy",
        "dataset.edit_working_copy","dataset.delete","dataset.share",
        "dataset.manage_acl","working_copy.view","working_copy.modify",
        "working_copy.delete","audit.view","invitation.manage",
        "delegation.manage","excel.mutate.original","excel.mutate.working_copy",
    },
    "team_lead": {
        "data.view","analysis.run","worksheet.create","pivot.create",
        "worksheet.modify","operation.undo.own","history.view",
        "organization.view","membership.view","dataset.view_original",
        "dataset.create_working_copy","dataset.edit_working_copy",
        "working_copy.view","working_copy.modify","excel.mutate.working_copy",
    },
    "employee": {
        "data.view","analysis.run","worksheet.create","pivot.create",
        "worksheet.modify","operation.undo.own","history.view",
        "organization.view","dataset.view_original",
        "dataset.create_working_copy","dataset.edit_working_copy",
        "working_copy.view","working_copy.modify","excel.mutate.working_copy",
    },
    "external_viewer": {"data.view","history.view","organization.view","dataset.view_original"},
}

_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")

def validate_id(value: str, field: str) -> str:
    if not isinstance(value, str) or not _ID_RE.fullmatch(value):
        raise ValueError(f"Invalid {field}.")
    return value

def validate_action(action: str) -> str:
    if not isinstance(action, str) or action not in ACTIONS:
        raise ValueError("Invalid permission.")
    return action

def clean_permissions(values):
    if values is None:
        return []
    return sorted({validate_action(str(v)) for v in values})
