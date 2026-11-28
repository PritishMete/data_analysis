from pathlib import Path

from firebase_authz.middleware import route_policy


ROOT = Path(__file__).parents[1]


def test_oracle_routes_have_explicit_sensitive_route_policies():
    assert route_policy("/powerbi/detail-analysis") == ("analysis.run", True)
    assert route_policy("/powerbi/dashboard") == ("worksheet.create", True)
    assert route_policy("/v1/chat/plan") == ("analysis.run", True)
    assert route_policy("/v1/conversation/state/update") == ("analysis.run", True)
    assert route_policy("/v1/system/diagnostics") == ("analysis.run", True)


def test_worker_allows_only_pages_origin_and_forwards_originless_requests():
    worker = (ROOT / "deploy" / "cloudflare" / "insightflow-api.js").read_text()
    assert "if (origin && origin !== FRONTEND_ORIGIN)" in worker
    assert "if (request.method === \"OPTIONS\")" in worker
    assert "requestHeaders.delete(\"host\")" in worker
    assert "requestHeaders.set(\"X-Forwarded-Proto\", \"https\")" in worker


def test_flutter_privacy_boundary_is_documented_without_claiming_uploads_are_local():
    document = (ROOT / "docs" / "ORACLE_CUTOVER_PRIVACY_SECURITY.md").read_text()
    source_router = (ROOT / "apps" / "flutter_app" / "lib" / "features" / "pipelines" / "widgets" / "source_router.dart").read_text()
    assert "Raw bytes cross the client-to-Oracle boundary" in document
    assert "CORS controls browser permission" in document
    assert "Missing `Origin` is therefore not authentication" in document
    assert "Oracle-backed Detail Analysis service" in source_router
    assert "local Detail Analysis backend" not in source_router
