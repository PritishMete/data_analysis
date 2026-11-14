"""Production authorization startup must not silently fall back to Firebase."""

import pytest

import main


def test_missing_provider_defaults_to_supabase_and_fails_closed_without_database_url(monkeypatch):
    monkeypatch.delenv("AUTHZ_PERSISTENCE_PROVIDER", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)

    with pytest.raises(
        RuntimeError,
        match=r"\[authz\] DATABASE_URL is missing",
    ):
        main._run_production_authz_migrations()
