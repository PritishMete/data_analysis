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



class _ListUser:
    def __init__(self, user_id, email, confirmed=True):
        self.id = user_id
        self.email = email
        self.email_confirmed_at = "2026-01-01T00:00:00Z" if confirmed else None


class _ListResponse:
    def __init__(self, users, **metadata):
        self.users = users
        for key, value in metadata.items():
            setattr(self, key, value)


def test_find_user_by_email_supports_sdk_response_and_pagination():
    responses = iter(
        [
            _ListResponse([_ListUser("other", "other@example.com")], total=2),
            _ListResponse([_ListUser("target", "TARGET@example.com")], total=2),
        ]
    )
    with patch.object(
        supabase_admin,
        "_run_admin_operation",
        side_effect=lambda operation, callback: next(responses),
    ):
        assert supabase_admin.find_user_by_email(" target@example.com ") == {
            "user_id": "target",
            "email_confirmed": True,
        }


def test_find_user_by_email_supports_nested_data_response():
    response = {
        "data": {
            "users": [
                {
                    "id": "nested-user",
                    "email": "nested@example.com",
                    "email_confirmed_at": None,
                }
            ]
        }
    }
    with patch.object(
        supabase_admin,
        "_run_admin_operation",
        side_effect=lambda operation, callback: response,
    ):
        assert supabase_admin.find_user_by_email("nested@example.com") == {
            "user_id": "nested-user",
            "email_confirmed": False,
        }


def test_find_user_by_email_supports_list_data_response():
    response = type(
        "Response",
        (),
        {
            "data": [
                {
                    "id": "list-user",
                    "email": "LIST@example.com",
                    "email_confirmed_at": "2026-01-01T00:00:00Z",
                }
            ]
        },
    )()
    with patch.object(
        supabase_admin,
        "_run_admin_operation",
        side_effect=lambda operation, callback: response,
    ):
        assert supabase_admin.find_user_by_email("list@example.com") == {
            "user_id": "list-user",
            "email_confirmed": True,
        }


def test_existing_auth_user_error_only_matches_duplicate_422():
    assert supabase_admin.is_existing_auth_user_error(
        _AdminServerError("A user with this email address has already been registered")
    ) is False

    class Duplicate(Exception):
        status_code = 422

    assert supabase_admin.is_existing_auth_user_error(
        Duplicate("A user with this email address has already been registered")
    )
    assert not supabase_admin.is_existing_auth_user_error(
        Duplicate("Invalid invitation request")
    )


def test_admin_error_sanitization_redacts_bearer_tokens():
    message = supabase_admin._sanitized_exception_message(
        Exception("Bearer eyJheader.payload.signature")
    )
    assert "eyJheader" not in message
    assert "Bearer [REDACTED]" in message


def test_invitation_request_rejects_client_supplied_auth_user_id():
    from pydantic import ValidationError
    from firebase_authz.routes import InvitationRequest

    with pytest.raises(ValidationError):
        InvitationRequest(
            workspace_id="org_test",
            email="employee@example.com",
            role_id="employee",
            auth_user_id="arbitrary-client-user",
        )



def test_invite_user_by_email_passes_organization_name_to_supabase_template_data():
    class FakeAdmin:
        def __init__(self):
            self.options = None

        def invite_user_by_email(self, email, options):
            self.options = options
            return type("Response", (), {"user": type("User", (), {"id": "user-1", "email_confirmed_at": None})()})()

    fake = FakeAdmin()
    with patch.object(supabase_admin, "_run_admin_operation", side_effect=lambda operation, callback: callback(type("Client", (), {"auth": type("Auth", (), {"admin": fake})()})())):
        result = supabase_admin.invite_user_by_email(
            "employee@example.com",
            "https://example.com/invite",
            organization_name="Acme Analytics",
        )
    assert result["user_id"] == "user-1"
    assert fake.options["data"]["organization_name"] == "Acme Analytics"
    assert fake.options["redirect_to"] == "https://example.com/invite"
