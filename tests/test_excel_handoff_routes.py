from excel_auth_handoff.routes import router


def test_v2_handoff_router_registers_all_session_transitions():
    paths = {route.path for route in router.routes}
    expected = {
        "/v2/excel-auth/handoff/create",
        "/v2/excel-auth/handoff/browser/bind",
        "/v2/excel-auth/handoff/browser/candidate",
        "/v2/excel-auth/handoff/browser/status",
        "/v2/excel-auth/handoff/status",
        "/v2/excel-auth/handoff/approve",
        "/v2/excel-auth/handoff/browser/complete",
        "/v2/excel-auth/handoff/claim",
        "/v2/excel-auth/handoff/cancel",
        "/v2/excel-auth/handoff/retry",
    }
    assert expected <= paths
