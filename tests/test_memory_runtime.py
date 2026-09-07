from memory import _default_db_path


def test_memory_default_db_path_uses_runtime_directory(tmp_path, monkeypatch):
    runtime_dir = tmp_path / "teacher_runtime"
    monkeypatch.setenv("DATA_ANALYSIS_RUNTIME_DIR", str(runtime_dir))

    db_path = _default_db_path()

    assert db_path == runtime_dir / "ai_memory.db"
    assert db_path.parent.exists()
