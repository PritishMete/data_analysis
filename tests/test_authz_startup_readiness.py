"""Startup readiness regressions for required Supabase authorization initialization."""

import os
import unittest
from unittest.mock import patch

import main


class AuthorizationStartupReadinessTests(unittest.TestCase):
    def test_supabase_without_database_url_fails_closed(self):
        with patch.dict(os.environ, {"AUTHZ_PERSISTENCE_PROVIDER": "supabase"}, clear=False):
            os.environ.pop("DATABASE_URL", None)
            with self.assertRaisesRegex(RuntimeError, "refusing to start"):
                main._run_production_authz_migrations()

    def test_migration_failure_prevents_following_database_initialization(self):
        with (
            patch.object(main, "_run_production_authz_migrations", side_effect=RuntimeError("migration failed")),
            patch.object(main, "init_db") as init_db,
        ):
            with self.assertRaisesRegex(RuntimeError, "migration failed"):
                main._initialize_production_database()
            init_db.assert_not_called()

    def test_successful_migration_precedes_database_initialization(self):
        calls = []
        with (
            patch.object(main, "_run_production_authz_migrations", side_effect=lambda: calls.append("authz")),
            patch.object(main, "init_db", side_effect=lambda: calls.append("app-db")),
        ):
            main._initialize_production_database()
        self.assertEqual(calls, ["authz", "app-db"])


if __name__ == "__main__":
    unittest.main()
