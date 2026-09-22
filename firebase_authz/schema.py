from __future__ import annotations
import re

ACTIONS = frozenset({
    "data.view", "analysis.run", "worksheet.create", "pivot.create",
    "worksheet.modify", "worksheet.delete", "operation.undo.own",
    "operation.undo.other", "history.view", "users.manage", "roles.manage",
    "policies.manage",
})

DEFAULT_ROLES = {
    "owner": set(ACTIONS),
    "analyst": {"data.view","analysis.run","worksheet.create","pivot.create","worksheet.modify","operation.undo.own","history.view"},
    "viewer": {"data.view","history.view"},
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
