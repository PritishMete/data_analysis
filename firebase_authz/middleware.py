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
    ("/smart_query", "analysis.run", "workspace"),
    ("/analyze-report-focused", "analysis.run", "resource"),
    ("/analyze-report", "analysis.run", "resource"),
    ("/analyze", "analysis.run", "resource"),
    ("/analysis_business_context", "analysis.run", "resource"),
    ("/analyze-report-focused", "analysis.run", "resource"),
    ("/sentiment_analysis", "analysis.run", "workspace"),
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


# These managed-dataset routes enforce their complete authorization contract in
# dataset_storage.routes plus the proposal/grant services. The middleware must
# not reinterpret names such as "proposals" or "upload-grants" as dataset IDs.
MANAGED_DATASET_SERVICE_AUTH_POLICY = ("__service_authorized__", False)


def managed_dataset_route_policy(method: str, path: str) -> tuple[str, bool] | None:
    base = "/v1/managed-datasets"
    if path == base and method == "GET":
        return None
    if path == base and method == "POST":
        return "dataset.upload", False
    if path.startswith(base + "/"):
        suffix = path[len(base) + 1:]
        parts = suffix.split("/")
        if (
            (suffix in {"proposals", "upload-grants"} and method in {"GET", "POST"})
            or (
                len(parts) == 3
                and parts[0] == "working-copies"
                and parts[2] in {"profile", "rows"}
                and method == "GET"
            )
            or (len(parts) == 2 and parts[0] == "upload-grants" and method == "DELETE")
            or (len(parts) == 2 and parts[1] == "proposals" and method == "POST")
            or (
                len(parts) == 3
                and parts[0] == "proposals"
                and parts[2] == "decision"
                and method == "POST"
            )
        ):
            return MANAGED_DATASET_SERVICE_AUTH_POLICY
        # Dataset identity is already part of the protected URL. These reads
        # must use the same resource boundary as the service layer instead of
        # falling through to the generic analysis policy (which would require
        # a separate X-InsightFlow-Resource-ID header).
        if len(parts) == 1 and method == "GET":
            return "dataset.view_original", True
        if len(parts) == 2 and parts[1] in {"profile", "rows", "download"} and method == "GET":
            return "dataset.view_original", True
        if len(parts) == 2 and parts[1] == "versions" and method == "POST":
            return "dataset.upload", False
        if len(parts) == 2 and parts[1] == "working-copies" and method == "POST":
            return "dataset.create_working_copy", True
        if len(parts) == 1 and method == "DELETE":
            return "dataset.delete", True
    return None


def route_policy(path: str) -> tuple[str, bool] | None:
    if path in PUBLIC_PATHS or any(path.startswith(prefix) for prefix in PUBLIC_PREFIXES):
        return None
    for prefix, action, resource_mode in ROUTE_ACTIONS:
        if path == prefix or path.startswith(prefix):
            return action, resource_mode == "resource"
    # Any newly added API is protected by default. This prevents an endpoint
    # from accidentally becoming public just because its policy was not added.
    return "analysis.run", True


def _authentication_required() -> bool:
    """Allow auth bypass only in an explicitly marked, non-Render test process.

    INSIGHTFLOW_AUTH_REQUIRED=false is not a production kill switch. Render
    always enforces authentication, even if that variable is accidentally set
    to false or a test-mode variable leaks into the environment.
    """
    if os.getenv("RENDER") or os.getenv("RENDER_SERVICE_ID"):
        return True
    auth_required = os.getenv("INSIGHTFLOW_AUTH_REQUIRED", "true").strip().lower()
    if auth_required in {"1", "true", "yes", "on"}:
        return True
    environment = os.getenv("INSIGHTFLOW_ENV", "production").strip().lower()
    return environment not in {"test", "testing"}


class FirebaseAuthorizationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable):
        if not _authentication_required():
            return await call_next(request)

        managed_policy = managed_dataset_route_policy(request.method, request.url.path)
        if managed_policy == MANAGED_DATASET_SERVICE_AUTH_POLICY:
            # Proposal/grant handlers and working-copy profile/row handlers
            # perform verified-token, active-membership, role and exact-branch
            # checks in their service layer. Generic resource policy here would
            # misclassify fixed route names as resource IDs.
            return await call_next(request)
        if managed_policy is not None:
            policy = managed_policy
        elif request.url.path == "/v1/managed-datasets" and request.method == "GET":
            policy = None
        else:
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
            if claims.get("email_verified") is not True:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "Email verification required."},
                )

            workspace_id = request.headers.get("x-insightflow-workspace-id", "").strip()
            if not workspace_id:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "Workspace authorization context required."},
                )
            validate_id(workspace_id, "workspace ID")

            action, requires_resource = policy
            resource_id = request.headers.get("x-insightflow-resource-id", "").strip()
            if requires_resource and not resource_id and managed_policy is not None:
                # For managed-dataset endpoints the dataset ID is the resource
                # identifier by definition. Resolve it from the route rather
                # than requiring the browser to duplicate the same identity in
                # a mutable header. Authorization still verifies the resource
                # against the authenticated principal and organization below.
                suffix = request.url.path[len("/v1/managed-datasets") + 1:]
                parts = suffix.split("/")
                if parts and parts[0].strip():
                    resource_id = parts[0].strip()
            if requires_resource and not resource_id:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "Resource authorization context required."},
                )
            if resource_id:
                validate_id(resource_id, "resource ID")

            # Uploaded files are dataset ingress. Employees, analysts, Team Leads,
            # and other lower roles must never be able to bypass the managed-dataset
            # workflow by posting an arbitrary multipart file to a legacy analysis,
            # transform, Excel, or Power BI endpoint. Only roles with the explicit
            # dataset.upload capability may submit file content.
            is_multipart_upload = request.method in {"POST", "PUT", "PATCH"} and request.headers.get("content-type", "").lower().startswith("multipart/form-data")

            persistence_provider = os.getenv("AUTHZ_PERSISTENCE_PROVIDER", "").strip().lower()
            if persistence_provider != "supabase":
                # Never route a Supabase-authenticated request into legacy
                # Firebase authorization when configuration is absent or invalid.
                raise AuthenticationRequired(
                    "Supabase authorization is required; "
                    "AUTHZ_PERSISTENCE_PROVIDER must be 'supabase'."
                )
            from .supabase_provider import authorize as provider_authorize
            decision = provider_authorize(claims, workspace_id, action, resource_id or None)
            if is_multipart_upload:
                provider_authorize(claims, workspace_id, "dataset.upload", None)
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
