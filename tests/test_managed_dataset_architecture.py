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
