from core.db import _default_sqlite_path


def test_default_sqlite_path_creates_runtime_directory(tmp_path, monkeypatch):
    runtime_dir = tmp_path / "nested" / "runtime"
    monkeypatch.setenv("DATA_ANALYSIS_RUNTIME_DIR", str(runtime_dir))

    db_path = _default_sqlite_path()

    assert db_path == runtime_dir / "enterprise_registry.db"
    assert db_path.parent.exists()
