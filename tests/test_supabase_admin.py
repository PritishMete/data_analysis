import os
import unittest
from unittest.mock import patch

from firebase_authz import supabase_admin


class _AdminRejected(Exception):
    status_code = 401


class _AdminServerError(Exception):
    status_code = 500


class SupabaseAdminCredentialTests(unittest.TestCase):
    def test_secret_key_is_preferred_over_service_role(self):
        with patch.dict(
            os.environ,
            {
                "SUPABASE_SECRET_KEY": "sb_secret_test",
                "SUPABASE_SERVICE_ROLE_KEY": "service_role_test",
                "SUPABASE_URL": "https://example.supabase.co",
            },
            clear=False,
        ):
            self.assertEqual(
                supabase_admin._credential_candidates(),
                [
                    ("SUPABASE_SECRET_KEY", "sb_secret_test"),
                    ("SUPABASE_SERVICE_ROLE_KEY", "service_role_test"),
                ],
            )

    def test_service_role_is_used_when_secret_key_is_rejected(self):
        calls = []

        def fake_client(source, credential):
            calls.append(source)
            if source == "SUPABASE_SECRET_KEY":
                raise _AdminRejected("invalid secret")
            return {"source": source}

        with patch.dict(
            os.environ,
            {
                "SUPABASE_SECRET_KEY": "sb_secret_test",
                "SUPABASE_SERVICE_ROLE_KEY": "service_role_test",
                "SUPABASE_URL": "https://example.supabase.co",
            },
            clear=False,
        ), patch.object(supabase_admin, "_credential_client", side_effect=fake_client):
            result = supabase_admin._run_admin_operation("list_users", lambda client: client)

        self.assertEqual(result, {"source": "SUPABASE_SERVICE_ROLE_KEY"})
        self.assertEqual(
            calls,
            ["SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY"],
        )

    def test_all_rejected_credentials_raise_credential_error(self):
        def fake_client(source, credential):
            raise _AdminRejected("invalid credential")

        with patch.dict(
            os.environ,
            {
                "SUPABASE_SECRET_KEY": "sb_secret_test",
                "SUPABASE_SERVICE_ROLE_KEY": "service_role_test",
                "SUPABASE_URL": "https://example.supabase.co",
            },
            clear=False,
        ), patch.object(supabase_admin, "_credential_client", side_effect=fake_client):
            with self.assertRaises(supabase_admin.SupabaseAdminCredentialError):
                supabase_admin._run_admin_operation("invite_user_by_email", lambda client: client)

    def test_non_auth_admin_failure_is_not_classified_as_credential_failure(self):
        def fake_client(source, credential):
            raise _AdminServerError("upstream failure")

        with patch.dict(
            os.environ,
            {
                "SUPABASE_SECRET_KEY": "sb_secret_test",
                "SUPABASE_SERVICE_ROLE_KEY": "service_role_test",
                "SUPABASE_URL": "https://example.supabase.co",
            },
            clear=False,
        ), patch.object(supabase_admin, "_credential_client", side_effect=fake_client):
            with self.assertRaises(supabase_admin.SupabaseAdminOperationError) as ctx:
                supabase_admin._run_admin_operation("list_users", lambda client: client)

        self.assertNotIsInstance(
            ctx.exception,
            supabase_admin.SupabaseAdminCredentialError,
        )


if __name__ == "__main__":
    unittest.main()
