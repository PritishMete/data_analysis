from __future__ import annotations

from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any
import uuid


class TransformationStatus(str, Enum):
    PLANNED = "planned"
    APPLIED = "applied"
    VALIDATED = "validated"
    FAILED = "failed"
    SUPERSEDED = "superseded"


@dataclass(frozen=True)
class TransformationStep:
    operation_id: str
    operation_type: str
    target_table: str
    target_fields: list[str]
    semantic_role: str | None
    parameters: dict[str, Any]
    reason: str
    confidence: float
    destructive: bool
    reversible: bool
    validation_rules: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class TransformationPlan:
    plan_id: str
    source_version: str
    steps: list[TransformationStep]
    mode: str = "specific"

    @classmethod
    def create(cls, source_version: str, steps: list[TransformationStep], mode: str = "specific") -> "TransformationPlan":
        return cls(plan_id=f"plan-{uuid.uuid4().hex[:12]}", source_version=source_version, steps=steps, mode=mode)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class DatasetVersion:
    version_id: str
    dataset_id: str
    parent_version: str | None
    kind: str
    sequence: int
    status: str


@dataclass(frozen=True)
class LineageRecord:
    transformation_id: str
    dataset_id: str
    source_version: str
    target_version: str
    sequence: int
    operation: str
    affected_fields: list[str]
    affected_row_count: int
    reason: str
    parameters: dict[str, Any]
    validation_result: dict[str, Any]
    reversible: bool
    status: str
    timestamp_order: int


class DataWorkspaceLineage:
    """Metadata-only lineage registry.

    It intentionally stores no row values or dataframe snapshots. Existing
    TransformationHistory remains responsible for local undo snapshots in a
    live session; this registry provides durable-compatible version metadata
    and stale-result dependency semantics for the Data Workspace layer.
    """

    def __init__(self) -> None:
        self._versions: dict[str, DatasetVersion] = {}
        self._records: list[LineageRecord] = []
        self._result_dependencies: dict[str, set[str]] = {}
        self._stale_results: set[str] = set()

    def create_raw(self, dataset_id: str) -> DatasetVersion:
        version = DatasetVersion(f"{dataset_id}:v0", dataset_id, None, "raw", 0, "current")
        self._versions[version.version_id] = version
        return version

    def create_version(self, dataset_id: str, source_version: str, kind: str = "cleaned", status: str = "current") -> DatasetVersion:
        siblings = [v for v in self._versions.values() if v.dataset_id == dataset_id]
        sequence = max((v.sequence for v in siblings), default=-1) + 1
        version = DatasetVersion(f"{dataset_id}:v{sequence}", dataset_id, source_version, kind, sequence, status)
        self._versions[version.version_id] = version
        return version

    def record(self, *, dataset_id: str, source_version: str, target_version: str, operation: str,
               affected_fields: list[str], affected_row_count: int, reason: str,
               parameters: dict[str, Any], validation_result: dict[str, Any],
               reversible: bool, status: str = TransformationStatus.APPLIED.value) -> LineageRecord:
        record = LineageRecord(
            transformation_id=f"tx-{uuid.uuid4().hex[:12]}",
            dataset_id=dataset_id,
            source_version=source_version,
            target_version=target_version,
            sequence=len(self._records),
            operation=operation,
            affected_fields=list(affected_fields),
            affected_row_count=int(affected_row_count),
            reason=reason,
            parameters=dict(parameters),
            validation_result=dict(validation_result),
            reversible=bool(reversible),
            status=status,
            timestamp_order=len(self._records),
        )
        self._records.append(record)
        return record

    def register_analysis_result(self, result_id: str, dataset_version: str) -> None:
        self._result_dependencies.setdefault(dataset_version, set()).add(result_id)

    def invalidate_dependents(self, dataset_version: str) -> set[str]:
        stale = set(self._result_dependencies.get(dataset_version, set()))
        self._stale_results.update(stale)
        return stale

    def is_stale(self, result_id: str) -> bool:
        return result_id in self._stale_results

    def versions(self) -> list[DatasetVersion]:
        return list(self._versions.values())

    def records(self) -> list[LineageRecord]:
        return list(self._records)
