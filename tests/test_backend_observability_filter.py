"""Regression tests for separating customer request telemetry from admin traffic."""

from firebase_authz.observability import should_observe_path


def test_admin_console_requests_are_not_customer_backend_traffic():
    assert not should_observe_path("/v1/company-admin/overview")
    assert not should_observe_path("/v1/company-admin/backend-requests")
    assert not should_observe_path("/v1/company-admin/audit")
    assert not should_observe_path("/v1/admin/overview")
    assert not should_observe_path("/v1/admin/users")
    assert not should_observe_path("/v1/admin/audit")


def test_customer_diagnostic_event_ingestion_remains_observable():
    assert should_observe_path("/v1/admin/events")


def test_customer_application_api_requests_remain_observable():
    assert should_observe_path("/analyze")
    assert should_observe_path("/smart_query")


def test_health_and_telemetry_session_routes_are_excluded():
    assert not should_observe_path("/health")
    assert not should_observe_path("/v1/diagnostics/sessions")
    assert not should_observe_path("/v1/diagnostics/sessions/claim")
