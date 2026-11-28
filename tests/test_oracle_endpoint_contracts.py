import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


CRITICAL = {
    ("GET", "/health"),
    ("GET", "/v1/build-info"),
    ("GET", "/v1/authz/me"),
    ("POST", "/v1/authz/check"),
    ("POST", "/v1/chat/plan"),
    ("POST", "/v1/assistant/meta"),
    ("POST", "/v1/conversation/state/update"),
    ("GET", "/v1/conversation/state/{session_id}"),
    ("POST", "/v2/detail-analysis"),
    ("POST", "/v2/detail-analysis/path"),
    ("POST", "/powerbi/detail-analysis"),
    ("POST", "/powerbi/dashboard"),
    ("GET", "/powerbi/reports/{filename}"),
    ("GET", "/v1/managed-datasets/{dataset_id}/download"),
    ("POST", "/v1/diagnostics/events"),
    ("GET", "/v1/system/diagnostics"),
}


def _decorated_routes(path: Path):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    routes = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for decorator in node.decorator_list:
            if not isinstance(decorator, ast.Call) or not isinstance(decorator.func, ast.Attribute):
                continue
            if decorator.func.attr not in {"get", "post", "put", "patch", "delete"}:
                continue
            if decorator.args and isinstance(decorator.args[0], ast.Constant):
                routes.add((decorator.func.attr.upper(), decorator.args[0].value))
    return routes


def test_critical_contract_routes_are_registered():
    routes = _decorated_routes(ROOT / "main.py")
    routes |= _decorated_routes(ROOT / "secure_excel" / "routes.py")
    routes |= {(method, "/v1/authz" + path) for method, path in _decorated_routes(ROOT / "firebase_authz" / "routes.py")}
    routes |= {(method, "/v1/diagnostics" + path) for method, path in _decorated_routes(ROOT / "firebase_authz" / "admin_diagnostics.py")}
    routes |= {(method, "/v1/managed-datasets" + path) for method, path in _decorated_routes(ROOT / "dataset_storage" / "routes.py")}
    routes |= _decorated_routes(ROOT / "ai_routes.py")
    missing = sorted(CRITICAL - routes)
    assert not missing, f"critical routes missing from source registrations: {missing}"


def test_worker_preserves_api_contract_and_cors_headers():
    source = (ROOT / "deploy" / "cloudflare" / "insightflow-api.js").read_text(encoding="utf-8")
    for marker in (
        "incoming.pathname + incoming.search",
        "method: request.method",
        "init.body = request.body",
        "env.ORACLE_VPC.fetch(upstreamRequest)",
        '"Authorization"',
        '"X-InsightFlow-Workspace-ID"',
        '"X-InsightFlow-Resource-ID"',
        'status: 502',
    ):
        assert marker in source, f"Worker contract marker missing: {marker}"


def test_flutter_callers_and_matrix_stay_in_scope():
    matrix = (ROOT / "docs" / "ORACLE_ENDPOINT_CONTRACT_MATRIX.md").read_text(encoding="utf-8")
    callers = {
        "apps/flutter_app/lib/core/services/chat_reasoning_service.dart": "/v1/chat/plan",
        "apps/flutter_app/lib/core/services/conversation_state_service.dart": "/v1/conversation/",
        "apps/flutter_app/lib/core/services/powerbi_detail_analysis_service.dart": "/powerbi/detail-analysis",
        "apps/flutter_app/lib/core/services/diagnostic_telemetry_service.dart": "/v1/diagnostics/events",
        "apps/flutter_app/lib/features/auth/managed_dataset_access_workspace.dart": "/v1/managed-datasets/",
    }
    for relative, marker in callers.items():
        source = (ROOT / relative).read_text(encoding="utf-8")
        assert marker in source
        assert marker in matrix


def test_authz_policy_covers_sensitive_contracts():
    source = (ROOT / "firebase_authz" / "middleware.py").read_text(encoding="utf-8")
    for marker in (
        '("/v2/detail-analysis", "analysis.run", "resource")',
        '("/v1/chat/plan", "analysis.run", "resource")',
        '("/v1/assistant/meta", "data.view", "resource")',
        '("/powerbi/reports/", "data.view", "resource")',
        '"/v1/diagnostics"',
    ):
        assert marker in source
