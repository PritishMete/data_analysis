from __future__ import annotations

import copy
import io
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import pandas as pd

from datasets.repository import DatasetRepository
from query_history.models import QueryHistory
from query_history.repository import QueryHistoryRepository

from .collection import (
    ExampleAssessment,
    TrainingExportBundle,
    TrainingExportPolicy,
    _flatten_record,
    assess_entry,
    build_report,
    persist_bundle,
)

TRAINING_EXPORT_COLUMNS: list[str] = [
    "input.intent",
    "input.semantic_roles",
    "input.predicate_graph.logical_structure",
    "input.predicate_graph.predicate_count",
    "input.predicate_graph.operators",
    "input.step_count",
    "output.tool_graph",
    "metadata.quality",
    "metadata.plan_source",
    "metadata.execution_success",
    "metadata.critic_passed",
    "metadata.result_validation_passed",
    "metadata.plan_completeness_passed",
    "metadata.privacy_validation_passed",
    "metadata.no_unresolved_ambiguity",
    "metadata.no_critical_repair",
    "metadata.repair_count",
    "metadata.correction_state",
    "metadata.planner_version",
    "metadata.structural_fingerprint",
    "metadata.split",
    "metadata.source_record_id",
    "metadata.source_kind",
]

SUPPORTED_EXPORT_FORMATS: tuple[str, ...] = ("csv", "jsonl", "parquet", "report")


class TrainingDatasetExporter:
    """Builds privacy-safe, structurally deduplicated training candidates.

    The exporter never trains a model. It only reshapes already-stored
    query history rows into a safe, future-ready training dataset and
    accompanying report.
    """

    def __init__(
        self,
        history_repository: QueryHistoryRepository,
        dataset_repository: DatasetRepository,
        policy: TrainingExportPolicy | None = None,
    ) -> None:
        self.history_repository = history_repository
        self.dataset_repository = dataset_repository
        self.policy = policy or TrainingExportPolicy.from_env()

    # ── Collection ──────────────────────────────────────────────────────

    def collect(
        self,
        *,
        organization_id: str | None = None,
        dataset_id: str | None = None,
        schema_hash: str | None = None,
        only_successful: bool = False,
        limit: int = 5000,
    ) -> list[QueryHistory]:
        return self.history_repository.list_candidates(
            organization_id=organization_id,
            dataset_id=dataset_id,
            schema_hash=schema_hash,
            success=True if only_successful else None,
            limit=limit,
        )

    # ── Assessment / selection ──────────────────────────────────────────

    def assess(self, entries: list[QueryHistory]) -> list[ExampleAssessment]:
        return [assess_entry(entry, self.policy) for entry in entries]

    def _select_assessments(self, assessments: list[ExampleAssessment]) -> tuple[list[ExampleAssessment], int]:
        eligible_by_family: dict[str, list[ExampleAssessment]] = defaultdict(list)
        for assessment in assessments:
            if assessment.safe_record is not None and assessment.structural_fingerprint:
                eligible_by_family[assessment.structural_fingerprint].append(assessment)

        selected: list[ExampleAssessment] = []
        intent_counts: dict[str, int] = defaultdict(int)
        tool_counts: dict[str, int] = defaultdict(int)
        duplicates_removed = 0

        family_order = sorted(
            eligible_by_family.items(),
            key=lambda item: (
                -max((candidate.quality_score for candidate in item[1]), default=0.0),
                item[0],
            ),
        )

        for _, family in family_order:
            family.sort(key=lambda candidate: (-candidate.quality_score, candidate.entry.id))
            keep = family[: self.policy.max_examples_per_family]
            dropped = family[self.policy.max_examples_per_family :]
            for candidate in dropped:
                if candidate.safe_record is not None:
                    candidate.safe_record = None
                candidate.eligible = False
                candidate.rejection_reasons.append("duplicate_family")
                duplicates_removed += 1

            for candidate in keep:
                if intent_counts[candidate.intent] >= self.policy.max_examples_per_intent:
                    if candidate.safe_record is not None:
                        candidate.safe_record = None
                    candidate.eligible = False
                    candidate.rejection_reasons.append("intent_cap_reached")
                    continue
                if tool_counts[candidate.tool_graph_key] >= self.policy.max_examples_per_tool_graph:
                    if candidate.safe_record is not None:
                        candidate.safe_record = None
                    candidate.eligible = False
                    candidate.rejection_reasons.append("tool_graph_cap_reached")
                    continue

                selected.append(candidate)
                intent_counts[candidate.intent] += 1
                tool_counts[candidate.tool_graph_key] += 1

        return selected, duplicates_removed

    def _finalize_record(self, assessment: ExampleAssessment) -> dict[str, Any]:
        record = copy.deepcopy(assessment.safe_record or {})
        metadata = dict(record.get("metadata") or {})
        metadata.update(
            {
                "split": assessment.split,
                "structural_fingerprint": assessment.structural_fingerprint,
                "source_record_id": assessment.entry.id,
                "source_kind": "experience",
                "tool_graph_key": assessment.tool_graph_key,
                "semantic_role_pattern": assessment.semantic_role_pattern,
                "predicate_complexity": assessment.predicate_complexity,
                "step_count": assessment.step_count,
            }
        )
        record["metadata"] = metadata
        return record

    def build_bundle(
        self,
        entries: list[QueryHistory],
        *,
        persist: bool = False,
        output_dir: str | Path | None = None,
    ) -> TrainingExportBundle:
        assessments = self.assess(entries)
        selected_assessments, duplicates_removed = self._select_assessments(assessments)
        records = [self._finalize_record(assessment) for assessment in selected_assessments]

        split_buckets: dict[str, list[dict[str, Any]]] = {"train": [], "validation": [], "test": []}
        for record in records:
            split = str((record.get("metadata") or {}).get("split") or "train")
            if split not in split_buckets:
                split = "train"
            split_buckets[split].append(record)

        report = build_report(
            assessments,
            records,
            policy=self.policy,
            duplicates_removed=duplicates_removed,
        )
        bundle = TrainingExportBundle(records=records, report=report, splits=split_buckets)
        if persist:
            bundle = persist_bundle(bundle, output_dir=Path(output_dir) if output_dir is not None else None)
        return bundle

    def collect_bundle(
        self,
        *,
        organization_id: str | None = None,
        dataset_id: str | None = None,
        schema_hash: str | None = None,
        only_successful: bool = False,
        limit: int = 5000,
        persist: bool = False,
        output_dir: str | Path | None = None,
    ) -> TrainingExportBundle:
        entries = self.collect(
            organization_id=organization_id,
            dataset_id=dataset_id,
            schema_hash=schema_hash,
            only_successful=only_successful,
            limit=limit,
        )
        return self.build_bundle(entries, persist=persist, output_dir=output_dir)

    # ── Serialization ───────────────────────────────────────────────────

    def _records_dataframe(self, records: list[dict[str, Any]]) -> pd.DataFrame:
        flattened = [_flatten_record(record) for record in records]
        df = pd.DataFrame(flattened, columns=TRAINING_EXPORT_COLUMNS)
        return df

    def render_csv(self, records: list[dict[str, Any]]) -> bytes:
        return self._records_dataframe(records).to_csv(index=False).encode("utf-8")

    def render_jsonl(self, records: list[dict[str, Any]]) -> bytes:
        lines = [json.dumps(record, ensure_ascii=False, sort_keys=True, default=str) for record in records]
        return ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")

    def render_parquet(self, records: list[dict[str, Any]]) -> bytes:
        buffer = io.BytesIO()
        self._records_dataframe(records).to_parquet(buffer, index=False, engine="pyarrow")
        return buffer.getvalue()

    def export_csv(self, entries: list[QueryHistory]) -> bytes:
        bundle = self.build_bundle(entries)
        return self.render_csv(bundle.records)

    def export_jsonl(self, entries: list[QueryHistory]) -> bytes:
        bundle = self.build_bundle(entries)
        return self.render_jsonl(bundle.records)

    def export_parquet(self, entries: list[QueryHistory]) -> bytes:
        bundle = self.build_bundle(entries)
        return self.render_parquet(bundle.records)

    def export(self, entries: list[QueryHistory], *, fmt: str) -> bytes:
        fmt = fmt.lower()
        if fmt == "csv":
            return self.export_csv(entries)
        if fmt == "jsonl":
            return self.export_jsonl(entries)
        if fmt == "parquet":
            return self.export_parquet(entries)
        raise ValueError(f"unsupported export format: {fmt!r} (expected one of {SUPPORTED_EXPORT_FORMATS})")

    def render(self, records: list[dict[str, Any]], *, fmt: str) -> bytes:
        fmt = fmt.lower()
        if fmt == "csv":
            return self.render_csv(records)
        if fmt == "jsonl":
            return self.render_jsonl(records)
        if fmt == "parquet":
            return self.render_parquet(records)
        raise ValueError(f"unsupported export format: {fmt!r} (expected one of {SUPPORTED_EXPORT_FORMATS})")
