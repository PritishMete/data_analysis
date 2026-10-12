"""Test-only authenticated identity for root-level smart-query route tests."""

import pytest


@pytest.fixture(autouse=True)
def _authenticated_smart_query_route_tests(monkeypatch, request):
    # This root-level test file is outside tests/conftest.py's directory scope.
    # Give its route-behavior tests the same deterministic test principal while
    # leaving the dedicated middleware/auth-boundary tests untouched.
    if request.node.path.name != "test_smart_query_error_handling.py":
        return

    from fastapi.testclient import TestClient
    import firebase_authz.middleware as middleware
    from firebase_authz import supabase_provider

    test_token = "insightflow-ci-test-token"
    workspace_id = "workspace_ci_test"
    resource_id = "resource_ci_test"

    original_init = TestClient.__init__

    def init_with_test_identity(self, app, *args, **kwargs):
        if kwargs.get("headers") is None:
            kwargs["headers"] = {
                "Authorization": f"Bearer {test_token}",
                "X-InsightFlow-Workspace-ID": workspace_id,
                "X-InsightFlow-Resource-ID": resource_id,
            }
        original_init(self, app, *args, **kwargs)

    monkeypatch.setattr(TestClient, "__init__", init_with_test_identity)

    original_verify = middleware.verify_id_token

    def verify_test_token(token):
        if token == test_token:
            return {
                "uid": "ci-test-user",
                "sub": "ci-test-user",
                "provider": "supabase",
                "email": "ci-test@example.com",
                "email_verified": True,
            }
        return original_verify(token)

    monkeypatch.setattr(middleware, "verify_id_token", verify_test_token)

    original_authorize = middleware.authorization

    def authorize_test_user(uid, requested_workspace, action, requested_resource=None):
        if uid == "ci-test-user" and requested_workspace == workspace_id:
            return {
                "allowed": True,
                "uid": uid,
                "workspace_id": requested_workspace,
                "resource_id": requested_resource,
                "action": action,
            }
        return original_authorize(uid, requested_workspace, action, requested_resource)

    monkeypatch.setattr(middleware, "authorization", authorize_test_user)

    original_provider_authorize = supabase_provider.authorize

    def authorize_test_provider(claims, requested_workspace, action, requested_resource=None):
        if claims.get("uid") == "ci-test-user" and requested_workspace == workspace_id:
            return {
                "allowed": True,
                "uid": "ci-test-user",
                "workspace_id": requested_workspace,
                "resource_id": requested_resource,
                "action": action,
            }
        return original_provider_authorize(
            claims, requested_workspace, action, requested_resource
        )

    monkeypatch.setattr(supabase_provider, "authorize", authorize_test_provider)
