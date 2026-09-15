from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any


@dataclass(frozen=True)
class CorrectionPlan:
    action: str  # UNDO, CORRECT, REAPPLY, REBUILD_FROM_VERSION
    transformation_id: str
    source_version: str
    target_version: str | None = None
    reason: str = ""
    replacement_parameters: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class StaleResult:
    result_id: str
    dataset_version: str
    status: str = "STALE"
    reason: str = "Underlying dataset version changed"


class CorrectionPlanner:
    """Plans corrections without mutating lineage history."""

    _ACTIONS = {"UNDO", "CORRECT", "REAPPLY", "REBUILD_FROM_VERSION"}

    def plan(self, action: str, transformation_id: str, source_version: str,
             *, target_version: str | None = None, reason: str = "",
             replacement_parameters: dict[str, Any] | None = None) -> CorrectionPlan:
        normalized = action.upper()
        if normalized not in self._ACTIONS:
            raise ValueError(f"Unsupported correction action: {action}")
        return CorrectionPlan(
            action=normalized,
            transformation_id=transformation_id,
            source_version=source_version,
            target_version=target_version,
            reason=reason,
            replacement_parameters=dict(replacement_parameters or {}),
        )
