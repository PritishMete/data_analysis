from pathlib import Path

from firebase_authz.company_admin_diagnostics import _customer_backend_route_filter


ROOT = Path(__file__).resolve().parents[1]


def test_customer_backend_route_filter_excludes_admin_control_plane_routes():
    clause = _customer_backend_route_filter()

    assert "e.route <> '/v1/company-admin'" in clause
    assert "e.route NOT LIKE '/v1/company-admin/%'" in clause
    assert "e.route <> '/v1/admin'" in clause
    assert "e.route NOT LIKE '/v1/admin/%' OR e.route = '/v1/admin/events'" in clause
    assert "e.route <> '/v1/diagnostics'" in clause
    assert "e.route NOT LIKE '/v1/diagnostics/%'" in clause


def test_customer_backend_route_filter_keeps_health_and_docs_out_of_metrics():
    clause = _customer_backend_route_filter()

    assert "'/health'" in clause
    assert "'/ping'" in clause
    assert "'/openapi.json'" in clause
    assert "e.route NOT LIKE '/docs%'" in clause
    assert "e.route NOT LIKE '/redoc%'" in clause


def test_overview_and_backend_request_list_share_the_same_customer_scope():
    source = (ROOT / "firebase_authz" / "company_admin_diagnostics.py").read_text(encoding="utf-8")
    overview = source.split('@router.get("/overview")', 1)[1].split('@router.get("/users")', 1)[0]
    request_list = source.split('@router.get("/backend-requests")', 1)[1].split('@router.get("/audit")', 1)[0]

    assert overview.count("_customer_backend_route_filter()") == 2
    assert "backend_requests" in overview
    assert "backend_errors" in overview
    assert "WHERE {_customer_backend_route_filter()}" in request_list
