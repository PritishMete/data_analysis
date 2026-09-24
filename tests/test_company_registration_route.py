from firebase_authz.routes import router


def test_company_registration_uses_authoritative_bootstrap_route():
    routes = {
        (route.path, method)
        for route in router.routes
        for method in getattr(route, "methods", set())
    }
    assert ("/v1/authz/bootstrap-owner", "POST") in routes
