from __future__ import annotations

ACTIONS = {
    "data.view", "analysis.run", "worksheet.create", "pivot.create",
    "worksheet.modify", "worksheet.delete", "operation.undo.own",
    "operation.undo.other", "history.view", "users.manage", "roles.manage",
    "policies.manage",
}
DEFAULT_ROLES = {
    "owner": set(ACTIONS),
    "analyst": {"data.view","analysis.run","worksheet.create","pivot.create","worksheet.modify","operation.undo.own","history.view"},
    "viewer": {"data.view","history.view"},
}

def clean_permissions(values):
    return sorted({str(v) for v in (values or []) if str(v) in ACTIONS})
