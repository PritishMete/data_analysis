"""Startup readiness regressions for required Supabase authorization initialization."""

import os
import unittest
from unittest.mock import patch

import main
from fastapi.testclient import TestClient


class AuthorizationStartupReadinessTests(unittest.TestCase):
    def test_schema_verification_rejects_missing_table(self):
        class Inspector:
            def has_table(self, name): return name != "diagnostic_events"
            def get_columns(self, name): return [{"name": column} for column in main._REQUIRED_AUTHZ_COLUMNS[name]]
        with patch.object(main, "sqlalchemy_inspect", return_value=Inspector()):
            with self.assertRaisesRegex(RuntimeError, "schema is incomplete"):
                main._verify_required_schema()

    def test_schema_verification_rejects_missing_column(self):
        class Inspector:
            def has_table(self, name): return True
            def get_columns(self, name):
                columns = main._REQUIRED_AUTHZ_COLUMNS.get(name, {"id"})
                return [{"name": column} for column in columns if column != "payload"]
        with patch.object(main, "sqlalchemy_inspect", return_value=Inspector()):
            with self.assertRaisesRegex(RuntimeError, "schema is incomplete"):
                main._verify_required_schema()

    def test_schema_verification_accepts_required_schema(self):
        class Inspector:
            def has_table(self, name): return True
            def get_columns(self, name):
                return [{"name": column} for column in main._REQUIRED_AUTHZ_COLUMNS.get(name, {"id"})]
        with patch.object(main, "sqlalchemy_inspect", return_value=Inspector()):
            main._verify_required_schema()

    def test_main_source_has_no_migration_execution_path(self):
        source = open("main.py", encoding="utf-8").read()
        self.assertNotIn("run_migrations()", source)

    def test_startup_fails_closed_without_database_url(self):
        with patch.object(main, "init_db") as init_db:
            with self.assertRaisesRegex(RuntimeError, "DATABASE_URL is missing"):
                main._initialize_production_database()
            init_db.assert_not_called()

    def test_startup_does_not_invoke_migration_runner(self):
        with patch.dict(os.environ, {"AUTHZ_PERSISTENCE_PROVIDER": "sqlite", "DATABASE_URL": "sqlite://"}):
            with patch("tools.run_authz_migrations.run_migrations") as migrate, patch.object(main, "init_db"):
                main._initialize_production_database()
            migrate.assert_not_called()

    def test_health_remains_unready_when_database_initialization_fails(self):
        main._PRODUCTION_READY = False
        with patch.object(main, "_initialize_production_database"):
            with TestClient(main.app) as client:
                assert client.get("/health").status_code == 503

    def test_health_is_503_when_schema_verification_fails(self):
        main._PRODUCTION_READY = False
        with patch.dict(os.environ, {"AUTHZ_PERSISTENCE_PROVIDER": "supabase", "DATABASE_URL": "postgresql://isolated"}):
            with patch.object(main, "init_db"), patch.object(main._rate_limiter, "initialize"), patch.object(main, "_verify_required_schema", side_effect=RuntimeError("schema incomplete")):
                with self.assertRaisesRegex(RuntimeError, "schema incomplete"):
                    main._initialize_production_database()
        with patch.object(main, "_initialize_production_database"):
            with TestClient(main.app) as client:
                assert client.get("/health").status_code == 503

    def test_application_initialization_runs_without_migration(self):
        with patch.dict(os.environ, {"AUTHZ_PERSISTENCE_PROVIDER": "sqlite", "DATABASE_URL": "sqlite://"}):
            with patch.object(main, "init_db") as init_db:
                main._initialize_production_database()
                init_db.assert_called_once()


if __name__ == "__main__":
    unittest.main()
