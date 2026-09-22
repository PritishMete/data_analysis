from __future__ import annotations

import os
from typing import Callable

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from .service import (
    AuthenticationRequired,
    PermissionDenied,
    authorization,
    verify_id_token,
)
from .schema import validate_id


PUBLIC_PATHS = {
    "/",
    "/health",
    "/ping",
    "/powerbi/ping",
    "/v1/build-info",
}
PUBLIC_PREFIXES = (
    "/docs",
    "/redoc",
    "/openapi.json",
    "/v1/authz",
)
# Route-level policy is deliberately kept server-side. The client can supply
# workspace/resource context, but it cannot choose the permission required for
# an operation.
ROUTE_ACTIONS: list[tuple[str, str, str]] = [
    ("/transform/undo", "operation.undo.own", "resource"),
    ("/transform/redo", "operation.undo.own", "resource"),
    ("/transform/history/", "history.view", "resource"),
    ("/transform/", "worksheet.modify", "resource"),
    ("/agentic_sheet_name", "worksheet.create", "resource"),
    ("/agentic_command", "analysis.run", "resource"),
    ("/agentic_filter_intent", "analysis.run", "resource"),
    ("/agentic_filter_plan", "analysis.run", "resource"),
    ("/agentic_categorize", "analysis.run", "resource"),
    ("/agentic_command", "analysis.run", "resource"),
    ("/smart_query", "analysis.run", "resource"),
    ("/analyze-report-focused", "analysis.run", "resource"),
    ("/analyze-report", "analysis.run", "resource"),
    ("/analyze", "analysis.run", "resource"),
    ("/analysis_business_context", "analysis.run", "resource"),
    ("/analyze-report-focused", "analysis.run", "resource"),
    ("/sentiment_analysis", "analysis.run", "resource"),
    ("/location/enrich", "analysis.run", "resource"),
    ("/v2/excel/scan", "data.view", "resource"),
    ("/v2/excel/context", "data.view", "resource"),
    ("/v2/detail-analysis", "analysis.run", "resource"),
    ("/v2/detail-analysis/path", "analysis.run", "resource"),
    ("/v1/chat/plan", "analysis.run", "resource"),
    ("/powerbi/reports/", "data.view", "resource"),
    ("/powerbi/dashboard", "worksheet.create", "resource"),
    ("/powerbi/", "analysis.run", "resource"),
    ("/clean_data", "worksheet.modify", "resource"),
    ("/excel/query", "analysis.run", "resource"),
    ("/excel/detail-analysis", "analysis.run", "resource"),
    ("/excel/interpret", "analysis.run", "resource"),
    ("/excel/meta", "data.view", "resource"),
    ("/v1/assistant/meta", "data.view", "resource"),
]


def route_policy(path: str) -> tuple[str, bool] | None:
    if path in PUBLIC_PATHS or any(path.startswith(prefix) for prefix in PUBLIC_PREFIXES):
        return None
    for prefix, action, resource_mode in ROUTE_ACTIONS:
        if path == prefix or path.startswith(prefix):
            return action, resource_mode == "resource"
    # Any newly added API is protected by default. This prevents an endpoint
    # from accidentally becoming public just because its policy was not added.
    return "analysis.run", True


class FirebaseAuthorizationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable):
        if os.getenv("INSIGHTFLOW_AUTH_REQUIRED", "true").strip().lower() not in {
            "1",
            "true",
            "yes",
            "on",
        }:
            return await call_next(request)

        policy = route_policy(request.url.path)
        if policy is None:
            return await call_next(request)

        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer ") or not header[7:].strip():
            return JSONResponse(
                status_code=401,
                content={"detail": "Firebase authentication required."},
            )

        try:
            claims = verify_id_token(header[7:].strip())
            uid = str(claims.get("uid", "")).strip()
            if not uid:
                raise AuthenticationRequired("Firebase authentication failed.")

            workspace_id = request.headers.get("x-insightflow-workspace-id", "").strip()
            if not workspace_id:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "Workspace authorization context required."},
                )
            validate_id(workspace_id, "workspace ID")

            action, requires_resource = policy
            resource_id = request.headers.get("x-insightflow-resource-id", "").strip()
            if requires_resource and not resource_id:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "Resource authorization context required."},
                )
            if resource_id:
                validate_id(resource_id, "resource ID")

            decision = authorization(uid, workspace_id, action, resource_id or None)
            request.state.firebase_uid = uid
            request.state.workspace_id = workspace_id
            request.state.resource_id = resource_id or None
            request.state.authorization = decision
            return await call_next(request)
        except (AuthenticationRequired, PermissionDenied, ValueError):
            return JSONResponse(
                status_code=403,
                content={"detail": "Permission denied."},
            )
