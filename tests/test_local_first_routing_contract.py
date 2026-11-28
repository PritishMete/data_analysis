from firebase_authz.middleware import route_policy


def test_powerbi_upload_routes_require_authenticated_analysis_context():
    assert route_policy("/powerbi/detail-analysis") == ("analysis.run", True)
    assert route_policy("/powerbi/customer-clean") == ("analysis.run", True)
    assert route_policy("/powerbi/product-clean") == ("analysis.run", True)
    assert route_policy("/powerbi/order-clean") == ("analysis.run", True)
    assert route_policy("/powerbi/date-dimension") == ("analysis.run", True)
    assert route_policy("/powerbi/business-analysis") == ("analysis.run", True)
    assert route_policy("/powerbi/dashboard") == ("worksheet.create", True)


def test_local_health_check_is_public_but_powerbi_ping_is_not_an_upload_path():
    assert route_policy("/powerbi/ping") is None
    assert route_policy("/health") is None
