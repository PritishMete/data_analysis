import inspect
from pathlib import Path


def test_managed_dataset_storage_has_no_firebase_dependency():
    root = Path(__file__).resolve().parents[1]
    source_paths = [
        root / "dataset_storage" / "provider.py",
        root / "dataset_storage" / "service.py",
        root / "dataset_storage" / "routes.py",
        root / ".env.example",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in source_paths).lower()
    assert "firebase_storage" not in combined
    assert "firebase_storage_bucket" not in combined
    assert "firebase storage" not in combined


def test_managed_dataset_http_lifecycle_is_the_public_dataset_path():
    root = Path(__file__).resolve().parents[1]
    main = (root / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(managed_dataset_router)" in main
    assert "app.include_router(dataset_registry_router)" not in main
    assert "app.include_router(ingestion_router)" not in main


def test_managed_dataset_profile_route_exists():
    root = Path(__file__).resolve().parents[1]
    routes = (root / "dataset_storage" / "routes.py").read_text(encoding="utf-8")
    assert '/{dataset_id}/profile' in routes
    assert 'X-InsightFlow-Workspace-ID' in routes

def test_managed_dataset_upload_accepts_a_user_defined_dataset_name():
    from dataset_storage.routes import router as dataset_storage_router

    upload_route = next(
        route for route in dataset_storage_router.routes
        if route.path == "/v1/managed-datasets" and "POST" in route.methods
    )
    body_fields = {parameter.name for parameter in upload_route.dependant.body_params}
    assert "dataset_name" in body_fields



def test_managed_dataset_file_ingestion_routes_are_threadpool_dispatched():
    # These handlers perform synchronous authentication, CSV parsing, Pandas
    # profiling and database writes. FastAPI sends normal def endpoints to its
    # worker threadpool, keeping the ASGI event loop free for /health checks.
    from dataset_storage.routes import router as managed_dataset_router

    file_upload_paths = {
        "/v1/managed-datasets",
        "/v1/managed-datasets/{dataset_id}/versions",
        "/v1/managed-datasets/proposals",
        "/v1/managed-datasets/{dataset_id}/proposals",
    }
    routes_by_path = {
        route.path: route
        for route in managed_dataset_router.routes
        if "POST" in route.methods
    }

    for path in file_upload_paths:
        assert path in routes_by_path
        assert not inspect.iscoroutinefunction(routes_by_path[path].endpoint)


def test_duplicate_replacement_requires_one_unambiguous_dataset():
    from dataset_storage.service import _single_replacement_target

    same_dataset_for_name_and_content = [{
        "dataset_id": "dataset-a",
        "reasons": ["name", "content"],
    }]
    two_different_datasets = [
        {"dataset_id": "dataset-a", "reasons": ["name"]},
        {"dataset_id": "dataset-b", "reasons": ["content"]},
    ]
    hidden_cross_branch_match = [{
        "dataset_id": None,
        "reasons": ["content_outside_branch"],
        "code": "content_outside_branch",
    }]

    assert _single_replacement_target(same_dataset_for_name_and_content) == "dataset-a"
    assert _single_replacement_target(two_different_datasets) is None
    assert _single_replacement_target(hidden_cross_branch_match) is None
    assert _single_replacement_target([]) is None


def test_stale_upload_recovery_preserves_pending_proposals_and_active_uploads():
    root = Path(__file__).resolve().parents[1]
    service = (root / "dataset_storage" / "service.py").read_text(encoding="utf-8")

    assert "def _recover_stale_processing_uploads" in service
    assert "pg_try_advisory_lock" in service
    assert '~DatasetVersion.version_id.like("p%")' in service
    assert "STALE_MANAGED_DATASET_PROCESSING_SECONDS" in service


def test_cross_branch_duplicate_response_does_not_include_other_branch_identity():
    root = Path(__file__).resolve().parents[1]
    service = (root / "dataset_storage" / "service.py").read_text(encoding="utf-8")

    assert '"code": "content_outside_branch"' in service
    assert '"dataset_id": None' in service
    assert '"dataset_name": None' in service
    assert "def _single_replacement_target" in service
    assert 'conflict["code"] = "upload_in_progress"' in service


def test_managed_dataset_uploads_are_serialized_and_ui_requires_ready_status():
    root = Path(__file__).resolve().parents[1]
    service = (root / "dataset_storage" / "service.py").read_text(encoding="utf-8")
    workspace = (
        root / "flutter_detail_source" / "lib" / "features" / "auth"
        / "managed_dataset_access_workspace.dart"
    ).read_text(encoding="utf-8")

    assert "pg_advisory_lock(hashtextextended(:lock_key, 0))" in service
    assert "repo.db.get_bind().connect()" in service
    assert 'execution_options(isolation_level="AUTOCOMMIT")' in service
    assert "pg_advisory_unlock_all()" in service
    assert "insightflow:managed-upload:name:" in service
    assert "insightflow:managed-upload:dataset:" in service
    assert "if (datasetStatus != 'ready')" in workspace
    assert "visibleConflictIds.length != 1" in workspace
    assert "hasUploadInProgress" in workspace
    assert "An upload for this dataset is still processing." in workspace


def test_failed_uploads_are_not_returned_as_active_datasets():
    root = Path(__file__).resolve().parents[1]
    service = (root / "dataset_storage" / "service.py").read_text(encoding="utf-8")

    assert 'if dataset.status in {"deleted", "failed"}:' in service


def test_managed_dataset_ui_only_reports_import_after_ready_confirmation():
    root = Path(__file__).resolve().parents[1]
    workspace = (
        root / "flutter_detail_source" / "lib" / "features" / "auth"
        / "managed_dataset_access_workspace.dart"
    ).read_text(encoding="utf-8")

    ready_check = workspace.index("if (datasetStatus != 'ready')")
    success_message = workspace.index("Managed dataset imported.")
    assert ready_check < success_message
    assert "The server did not confirm a published dataset." in workspace


def test_version_upload_refreshes_target_after_waiting_on_advisory_lock():
    root = Path(__file__).resolve().parents[1]
    service = (root / "dataset_storage" / "service.py").read_text(encoding="utf-8")
    upload = service[
        service.index("def upload_managed_dataset_stream("):
        service.index("\ndef upload_managed_dataset(", service.index("def upload_managed_dataset_stream("))
    ]

    lock_position = upload.rindex(
        "upload_lock_connection, upload_lock_keys = _acquire_managed_dataset_upload_locks("
    )
    refresh_position = upload.index("execution_options(populate_existing=True)")
    base_version_position = upload.index(
        "base_version_id = current_dataset.current_version_id"
    )

    assert lock_position < refresh_position < base_version_position
    assert ".with_for_update()" in upload[refresh_position - 160:refresh_position]
