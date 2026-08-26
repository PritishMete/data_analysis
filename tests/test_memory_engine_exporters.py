import io
import json

import pandas as pd
import pyarrow.parquet as pq
from fastapi.testclient import TestClient

import main
from datasets.repository import DatasetRepository
from datasets.service import DatasetRegistryService
from memory_engine.collection import TrainingExportPolicy
from memory_engine.exporters import TRAINING_EXPORT_COLUMNS, TrainingDatasetExporter
from memory_engine.routes import get_training_dataset_exporter
from query_history.repository import QueryHistoryRepository
from query_history.service import QueryHistoryService

SENSITIVE_VALUES = [
    "John Smith",
    "john@example.com",
    "ACC-9988",
    "SecretCompanyXYZ",
    "9876543210",
]


def _sales_df() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "Region": ["North", "South"],
            "Product": ["Widget", "Gadget"],
            "Quantity": [10, 5],
            "Revenue": [100.0, 200.0],
        }
    )


def _build(db_session, policy: TrainingExportPolicy | None = None):
    dataset_repo = DatasetRepository(db_session)
    registry_service = DatasetRegistryService(dataset_repo)
    history_service = QueryHistoryService(QueryHistoryRepository(db_session), dataset_repo)
    exporter = TrainingDatasetExporter(QueryHistoryRepository(db_session), dataset_repo, policy=policy)
    return registry_service, history_service, exporter


def _learning_metadata(
    *,
    quality_score: float,
    critic_passed: bool = True,
    result_validation_passed: bool = True,
    plan_completeness_passed: bool = True,
    privacy_validation_passed: bool = True,
    no_unresolved_ambiguity: bool = True,
    no_critical_repair: bool = True,
    repair_count: int = 0,
    correction_state: str = "validated",
    plan_source: str = "validated_template",
):
    return {
        "quality_score": quality_score,
        "critic_passed": critic_passed,
        "result_validation_passed": result_validation_passed,
        "plan_completeness_passed": plan_completeness_passed,
        "privacy_validation_passed": privacy_validation_passed,
        "no_unresolved_ambiguity": no_unresolved_ambiguity,
        "no_critical_repair": no_critical_repair,
        "repair_count": repair_count,
        "correction_state": correction_state,
        "plan_source": plan_source,
    }


def _eligible_pipeline(seed: int, *, quality_score: float = 0.97, plan_source: str = "validated_template") -> dict:
    return {
        "group_by": [f"Region_{seed}"],
        "metrics": [{"column": f"Revenue_{seed}", "function": "sum", "alias": f"total_revenue_{seed}"}],
        "filters": [{"column": f"Quantity_{seed}", "operator": "greater_than", "value": str(50 + seed)}],
        "tool_sequence": ["sql.filter", "sql.group_by"],
        "learning": _learning_metadata(quality_score=quality_score, plan_source=plan_source),
    }


def _seed_example(
    history_service: QueryHistoryService,
    *,
    user_query: str,
    dataset_id: str | None = None,
    intent: str | None = None,
    success: bool = True,
    generated_sql: str | None = "SELECT 1",
    python_pipeline: dict | list | None = None,
    feedback_score: int | None = 1,
):
    entry = history_service.log_execution(
        user_query=user_query,
        intent=intent,
        dataset_id=dataset_id,
        success=success,
        generated_sql=generated_sql,
        python_pipeline=python_pipeline,
    )
    if feedback_score is not None:
        history_service.record_feedback(entry.id, feedback_score)
    return entry


def _assert_no_literals(payload: object) -> None:
    serialized = json.dumps(payload, sort_keys=True, default=str)
    for literal in SENSITIVE_VALUES:
        assert literal not in serialized


def test_export_builds_safe_records_and_report(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="show John Smith from SecretCompanyXYZ with john@example.com and ACC-9988 and 9876543210",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline=_eligible_pipeline(1),
        feedback_score=1,
    )
    _seed_example(
        history_service,
        user_query="show same family but bad validation",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline={
            **_eligible_pipeline(2),
            "learning": {
                **_learning_metadata(quality_score=0.97),
                "result_validation_passed": False,
            },
        },
        feedback_score=1,
    )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert bundle.report["total_experiences_inspected"] == 2
    assert bundle.report["eligible_examples"] == 1
    assert bundle.report["rejected_examples"] == 1
    assert bundle.report["rejection_reasons"].get("result_validation_failed", 0) == 1
    assert bundle.report["average_quality"] >= 0.95
    assert len(bundle.records) == 1
    assert bundle.records[0]["metadata"]["split"] in {"train", "validation", "test"}

    _assert_no_literals(bundle.records)
    _assert_no_literals(bundle.report)


def test_export_rejects_result_validation_failure(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="bad result validation",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline={
            **_eligible_pipeline(1),
            "learning": {
                **_learning_metadata(quality_score=0.97, result_validation_passed=False),
            },
        },
    )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert bundle.report["eligible_examples"] == 0
    assert bundle.report["rejected_examples"] == 1
    assert bundle.report["rejection_reasons"].get("result_validation_failed", 0) == 1


def test_export_rejects_critic_failure(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="critic failure",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline={
            **_eligible_pipeline(1),
            "learning": {
                **_learning_metadata(quality_score=0.97, critic_passed=False),
            },
        },
    )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert bundle.report["eligible_examples"] == 0
    assert bundle.report["rejected_examples"] == 1
    assert bundle.report["rejection_reasons"].get("critic_failed", 0) == 1


def test_export_rejects_low_quality_by_default(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="low quality example",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline=_eligible_pipeline(1, quality_score=0.80),
    )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert bundle.report["eligible_examples"] == 0
    assert bundle.report["rejection_reasons"].get("quality_below_threshold", 0) == 1


def test_export_deduplicates_structural_family_and_keeps_best_quality(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    for seed, quality in enumerate((0.96, 0.98, 0.97), start=1):
        _seed_example(
            history_service,
            user_query=f"John Smith family variant {seed}",
            dataset_id=reg.dataset.dataset_id,
            python_pipeline=_eligible_pipeline(1, quality_score=quality),
        )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert len(bundle.records) == 1
    assert bundle.report["duplicates_removed"] == 2
    assert bundle.records[0]["metadata"]["quality"] == 0.98
    _assert_no_literals(bundle.records)


def test_export_split_assignment_keeps_family_together(db_session):
    policy = TrainingExportPolicy(
        max_examples_per_family=3,
        max_examples_per_intent=10,
        max_examples_per_tool_graph=10,
    )
    registry_service, history_service, exporter = _build(db_session, policy=policy)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    for seed in range(3):
        _seed_example(
            history_service,
            user_query=f"family split seed {seed}",
            dataset_id=reg.dataset.dataset_id,
            python_pipeline=_eligible_pipeline(7, quality_score=0.97),
        )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert len(bundle.records) == 3
    assert len({record["metadata"]["split"] for record in bundle.records}) == 1


def test_export_balances_heavy_intent_caps(db_session):
    policy = TrainingExportPolicy(
        max_examples_per_family=1,
        max_examples_per_intent=1,
        max_examples_per_tool_graph=10,
    )
    registry_service, history_service, exporter = _build(db_session, policy=policy)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="dominant family 1",
        dataset_id=reg.dataset.dataset_id,
        intent="aggregate",
        python_pipeline=_eligible_pipeline(1, quality_score=0.98),
    )
    _seed_example(
        history_service,
        user_query="dominant family 2",
        dataset_id=reg.dataset.dataset_id,
        intent="aggregate",
        python_pipeline={
            "group_by": ["Region_2"],
            "metrics": [{"column": "Revenue_2", "function": "sum", "alias": "total_revenue_2"}],
            "tool_sequence": ["sql.group_by"],
            "learning": _learning_metadata(quality_score=0.97),
        },
    )

    bundle = exporter.collect_bundle(organization_id="org_1")
    assert len(bundle.records) == 1
    assert bundle.report["rejection_reasons"].get("intent_cap_reached", 0) >= 1


def test_export_persists_split_files_and_report_without_sensitive_literals(tmp_path, db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="persist John Smith example",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline=_eligible_pipeline(1, quality_score=0.97),
    )

    output_dir = tmp_path / "training"
    bundle = exporter.collect_bundle(organization_id="org_1", persist=True, output_dir=output_dir)
    assert bundle.persisted_paths
    for name in ("train.jsonl", "validation.jsonl", "test.jsonl", "dataset_report.json"):
        assert (output_dir / name).exists()
        assert name in bundle.persisted_paths

    for path in output_dir.iterdir():
        text = path.read_text(encoding="utf-8")
        for literal in SENSITIVE_VALUES:
            assert literal not in text


def test_export_serialization_formats_are_safe(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )

    _seed_example(
        history_service,
        user_query="format example",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline=_eligible_pipeline(1, quality_score=0.97),
    )

    entries = exporter.collect(organization_id="org_1")
    csv_bytes = exporter.export_csv(entries)
    jsonl_bytes = exporter.export_jsonl(entries)
    parquet_bytes = exporter.export_parquet(entries)

    csv_df = pd.read_csv(io.BytesIO(csv_bytes))
    assert list(csv_df.columns) == TRAINING_EXPORT_COLUMNS

    jsonl_text = jsonl_bytes.decode("utf-8")
    assert "format example" not in jsonl_text

    table = pq.read_table(io.BytesIO(parquet_bytes))
    assert table.column_names == TRAINING_EXPORT_COLUMNS


def test_training_export_route_returns_report_and_validates_params(db_session):
    registry_service, history_service, exporter = _build(db_session)
    reg = registry_service.register_dataset(
        df=_sales_df(),
        raw_bytes=b"sales",
        organization_id="org_1",
        dataset_name="sales.csv",
        uploaded_by="p",
        source_type="csv",
    )
    _seed_example(
        history_service,
        user_query="route example",
        dataset_id=reg.dataset.dataset_id,
        python_pipeline=_eligible_pipeline(1, quality_score=0.97),
    )

    main.app.dependency_overrides[get_training_dataset_exporter] = lambda: exporter
    try:
        app = TestClient(main.app)
        report_response = app.get("/v2/memory-engine/training-export?format=report&persist=true&limit=10")
        assert report_response.status_code == 200
        report_payload = report_response.json()
        assert report_payload["exported"] is True
        assert report_payload["report"]["eligible_examples"] == 1
        assert report_payload["report"]["train_count"] + report_payload["report"]["validation_count"] + report_payload["report"]["test_count"] == 1
        _assert_no_literals(report_payload)

        csv_response = app.get("/v2/memory-engine/training-export?format=csv&limit=10")
        assert csv_response.status_code == 200
        assert csv_response.headers["content-type"].startswith("text/csv")

        bad_response = app.get("/v2/memory-engine/training-export?format=jsonl&limit=0")
        assert bad_response.status_code == 400
    finally:
        main.app.dependency_overrides.pop(get_training_dataset_exporter, None)
