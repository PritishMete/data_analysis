"""Production authorization startup must not silently fall back to Firebase."""

import pytest

import main


def test_missing_provider_defaults_to_supabase_and_fails_closed_without_database_url(monkeypatch):
    monkeypatch.delenv("AUTHZ_PERSISTENCE_PROVIDER", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)

    with pytest.raises(RuntimeError, match=r"\[authz\] DATABASE_URL is missing"):
        main._initialize_production_database()


def test_startup_never_invokes_migrations(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite://")
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "sqlite")
    monkeypatch.setattr(main, "init_db", lambda: None)
    monkeypatch.setattr(main._rate_limiter, "initialize", lambda: None)
    import tools.run_authz_migrations as runner
    monkeypatch.setattr(runner, "run_migrations", lambda: pytest.fail("startup invoked migrations"))
    main._initialize_production_database()
