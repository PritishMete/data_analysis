"""ASGI security controls that run before FastAPI parses request bodies."""

from __future__ import annotations

import os
import time
from collections.abc import Awaitable, Callable
from typing import Any

from fastapi.responses import JSONResponse
from sqlalchemy import text
from security_controls import configured_origins


ASGIApp = Callable[[dict[str, Any], Callable[[], Awaitable[dict[str, Any]]], Callable[[dict[str, Any]], Awaitable[None]]], Awaitable[None]]


def _positive_int(name: str, default: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default
    return max(1, min(value, maximum))


class RequestSizeLimitMiddleware:
    """Reject bodies before downstream parsers or upload handlers run."""

    def __init__(self, app: ASGIApp, max_bytes: int | None = None):
        self.app = app
        self.max_bytes = max_bytes or _positive_int(
            "INSIGHTFLOW_MAX_REQUEST_BYTES", 100 * 1024 * 1024, 500 * 1024 * 1024
        )

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        raw_length = headers.get(b"content-length")
        if raw_length:
            try:
                if int(raw_length) > self.max_bytes:
                    await JSONResponse(
                        {"detail": "Request body exceeds the configured limit."},
                        status_code=413,
                    )(scope, receive, send)
                    return
            except ValueError:
                await JSONResponse(
                    {"detail": "Invalid Content-Length header."}, status_code=400
                )(scope, receive, send)
                return

        consumed = 0
        buffered: list[dict[str, Any]] = []
        while True:
            message = await receive()
            if message["type"] != "http.request":
                buffered.append(message)
                break
            body = message.get("body", b"")
            consumed += len(body)
            if consumed > self.max_bytes:
                await JSONResponse(
                    {"detail": "Request body exceeds the configured limit."},
                    status_code=413,
                )(scope, receive, send)
                return
            buffered.append(message)
            if not message.get("more_body", False):
                break

        async def replay():
            if buffered:
                return buffered.pop(0)
            return {"type": "http.request", "body": b"", "more_body": False}

        await self.app(scope, replay, send)


class SecurityHeadersMiddleware:
    """Add headers that are safe for the JSON API and Flutter task pane."""

    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                names = {key.lower() for key, _ in headers}
                additions = {
                    b"x-content-type-options": b"nosniff",
                    b"x-frame-options": b"DENY",
                    b"referrer-policy": b"strict-origin-when-cross-origin",
                    b"cross-origin-resource-policy": b"same-origin",
                    b"cross-origin-opener-policy": b"same-origin",
                    b"permissions-policy": b"camera=(), microphone=(), geolocation=()",
                }
                # Render terminates TLS before forwarding to the ASGI process.
                # HSTS is therefore an explicit operator opt-in, not inferred
                # from request.scope["scheme"]. Never emit it in dev/test.
                if (
                    os.getenv("INSIGHTFLOW_ENV", "development").strip().lower() == "production"
                    and os.getenv("INSIGHTFLOW_HSTS_ENABLED", "").strip().lower() == "true"
                ):
                    additions[b"strict-transport-security"] = b"max-age=31536000; includeSubDomains"
                content_type = dict(headers).get(b"content-type", b"").lower()
                if content_type.startswith((b"application/json", b"text/plain")):
                    additions[b"content-security-policy"] = (
                        b"default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
                    )
                for key, value in additions.items():
                    if key not in names:
                        headers.append((key, value))
                await send({**message, "headers": headers})
                return
            await send(message)

        await self.app(scope, receive, send_with_headers)


class OriginProtectionMiddleware:
    """Reject cross-site state-changing requests and cookie-auth CSRF."""

    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        if scope.get("method", "GET").upper() in {"POST", "PUT", "PATCH", "DELETE"}:
            headers = {key.lower(): value.decode("latin1") for key, value in scope.get("headers", [])}
            origin = headers.get(b"origin")
            if origin and origin.rstrip("/") not in configured_origins():
                await JSONResponse({"detail": "Cross-origin request rejected."}, status_code=403)(scope, receive, send)
                return
            if headers.get(b"cookie") and not origin:
                await JSONResponse({"detail": "Origin header required for cookie-authenticated requests."}, status_code=403)(scope, receive, send)
                return
        await self.app(scope, receive, send)


class DatabaseRateLimiter:
    """Atomic database-backed fixed-window limiter for production instances."""

    def __init__(self, engine):
        self.engine = engine
        self._initialized = False

    def initialize(self) -> None:
        with self.engine.begin() as connection:
            connection.execute(text("""
                CREATE TABLE IF NOT EXISTS api_rate_limit_buckets (
                    bucket_key VARCHAR(255) PRIMARY KEY,
                    window_start BIGINT NOT NULL,
                    request_count INTEGER NOT NULL
                )
            """))
        self._initialized = True

    def allow(self, key: str, limit: int, window_seconds: int) -> tuple[bool, int]:
        # Test clients and lightweight ASGI embedders may not run FastAPI's
        # startup hooks. Ensure the limiter remains usable in those contexts;
        # production startup still creates the table before serving traffic.
        if not self._initialized:
            self.initialize()
        now = int(time.time())
        window = now - (now % window_seconds)
        with self.engine.begin() as connection:
            dialect = connection.dialect.name
            if dialect == "postgresql":
                row = connection.execute(text("""
                    INSERT INTO api_rate_limit_buckets
                        (bucket_key, window_start, request_count)
                    VALUES (:key, :window, 1)
                    ON CONFLICT (bucket_key) DO UPDATE SET
                        window_start = EXCLUDED.window_start,
                        request_count = CASE
                            WHEN api_rate_limit_buckets.window_start = EXCLUDED.window_start
                            THEN api_rate_limit_buckets.request_count + 1
                            ELSE 1
                        END
                    RETURNING window_start, request_count
                """), {"key": key, "window": window}).one()
            else:
                existing = connection.execute(text(
                    "SELECT window_start, request_count FROM api_rate_limit_buckets WHERE bucket_key=:key"
                ), {"key": key}).mappings().first()
                count = existing["request_count"] + 1 if existing and existing["window_start"] == window else 1
                connection.execute(text("""
                    INSERT INTO api_rate_limit_buckets(bucket_key, window_start, request_count)
                    VALUES (:key, :window, :count)
                    ON CONFLICT(bucket_key) DO UPDATE SET
                        window_start=excluded.window_start,
                        request_count=excluded.request_count
                """), {"key": key, "window": window, "count": count})
                row = (window, count)
            retry_after = max(1, window + window_seconds - now)
            return row[1] <= limit, retry_after


def rate_limit_policy(path: str, method: str) -> tuple[str, int] | None:
    if path.startswith("/v1/company-admin"):
        return "company-admin", _positive_int("INSIGHTFLOW_RATE_COMPANY_ADMIN_PER_MINUTE", 120, 1200)
    if path.startswith("/v1/excel-auth/handoff"):
        return "excel-auth-handoff", _positive_int("INSIGHTFLOW_RATE_EXCEL_HANDOFF_PER_MINUTE", 12, 60)
    if path.startswith("/v1/authz"):
        return "auth", _positive_int("INSIGHTFLOW_RATE_AUTH_PER_MINUTE", 30, 600)
    if path.startswith("/v1/managed-datasets") and method in {"POST", "PUT", "PATCH", "DELETE"}:
        return "dataset-write", _positive_int("INSIGHTFLOW_RATE_UPLOADS_PER_MINUTE", 20, 300)
    if path.startswith(("/analyze", "/agentic_", "/transform/", "/v2/", "/excel/", "/powerbi/")):
        return "expensive", _positive_int("INSIGHTFLOW_RATE_EXPENSIVE_PER_MINUTE", 60, 1200)
    if path.startswith("/v1/management"):
        return "management", _positive_int("INSIGHTFLOW_RATE_MANAGEMENT_PER_MINUTE", 120, 1200)
    return None


class RateLimitMiddleware:
    def __init__(self, app: ASGIApp, limiter: DatabaseRateLimiter):
        self.app = app
        self.limiter = limiter

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        policy = rate_limit_policy(scope.get("path", ""), scope.get("method", "GET"))
        if policy is None:
            await self.app(scope, receive, send)
            return
        # request.client is the directly connected peer. Arbitrary forwarded
        # headers are intentionally ignored because they are client-controlled.
        client = scope.get("client")
        address = client[0] if client else "unknown"
        category, limit = policy
        allowed, retry_after = self.limiter.allow(f"{category}:{address}", limit, 60)
        if not allowed:
            response = JSONResponse(
                {"detail": "Rate limit exceeded. Please retry later."},
                status_code=429,
                headers={"Retry-After": str(retry_after)},
            )
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)
