from core.db import _default_sqlite_path


def test_default_sqlite_path_creates_runtime_directory(tmp_path, monkeypatch):
    runtime_dir = tmp_path / "nested" / "runtime"
    monkeypatch.setenv("DATA_ANALYSIS_RUNTIME_DIR", str(runtime_dir))

    db_path = _default_sqlite_path()

    assert db_path == runtime_dir / "enterprise_registry.db"
    assert db_path.parent.exists()


def test_postgres_engine_uses_stale_connection_protection():
    from core import db

    if db.DATABASE_URL.startswith("sqlite"):
        return
    # The production engine is created once at import time; assert the
    # configuration source explicitly so future changes cannot silently drop
    # stale-connection protection for Render/Supabase.
    assert db._engine_pool_options["pool_pre_ping"] is True
    assert db._engine_pool_options["pool_recycle"] == 600
