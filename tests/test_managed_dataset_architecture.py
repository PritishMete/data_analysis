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
