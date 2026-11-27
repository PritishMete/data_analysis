"""Privacy-filtered request telemetry for InsightFlow backend operations."""
from __future__ import annotations

import hashlib
import logging
import re
import time
import traceback
import uuid
from typing import Callable

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware

from sqlalchemy import text
from core.db import SessionLocal

logger = logging.getLogger(__name__)

_BEARER = re.compile(r"(?i)bearer\s+[^\s,;]+")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")
_SECRET = re.compile(r"(?i)(?:sb_secret|sb_publishable)_[A-Za-z0-9_-]+")
_EMAIL = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)
_PHONE = re.compile(r"(?<!\w)(?:\+?\d[\d .()\-]{7,}\d)(?!\w)")


def sanitize_error_message(value: object, limit: int = 1200) -> str:
    message = str(value or "").strip()
    message = _BEARER.sub("Bearer [REDACTED]", message)
    message = _JWT.sub("[JWT_REDACTED]", message)
    message = _SECRET.sub("[SUPABASE_KEY_REDACTED]", message)
    message = _EMAIL.sub("[EMAIL_REDACTED]", message)
    message = _PHONE.sub("[PHONE_REDACTED]", message)
    return message[:limit]


def should_observe_path(path: str) -> bool:
    if path in {"/", "/health", "/ping", "/powerbi/ping", "/openapi.json"}:
        return False
    return not path.startswith(("/docs", "/redoc"))


class BackendRequestObservabilityMiddleware(BaseHTTPMiddleware):
    """Persist request outcomes without recording bodies, query strings, or secrets."""

    async def dispatch(self, request: Request, call_next: Callable):
        if not should_observe_path(request.url.path):
            return await call_next(request)

        started = time.perf_counter()
        request_id = request.headers.get("x-request-id", "").strip()
        if not request_id or len(request_id) > 128 or not re.fullmatch(r"[A-Za-z0-9._:-]+", request_id):
            request_id = "req_" + uuid.uuid4().hex
        status_code = 500
        error_type = None
        error_message = None
        error_stack = None
        response = None
        try:
            response = await call_next(request)
            status_code = response.status_code
            if status_code >= 500:
                error_type = f"HTTP_{status_code}"
                error_message = f"Backend returned HTTP {status_code}"
            elif status_code >= 400:
                error_type = f"HTTP_{status_code}"
                error_message = f"Request returned HTTP {status_code}"
            response.headers.setdefault("X-Request-ID", request_id)
            return response
        except Exception as exc:
            error_type = type(exc).__name__[:160]
            error_message = sanitize_error_message(exc)
            frames = traceback.extract_tb(exc.__traceback__)[-30:]
            error_stack = "\n".join(
                f"{frame.filename}:{frame.lineno} in {frame.name}" for frame in frames
            )[:8000]
            logger.error(
                "backend_request_failed request_id=%s exception=%s message=%s",
                request_id, error_type, error_message
            )
            raise
        finally:
            duration_ms = max(0, round((time.perf_counter() - started) * 1000))
            route = getattr(request.scope.get("route"), "path", None) or "/unmatched"
            route = str(route)[:240]
            subject = getattr(request.state, "firebase_uid", None)
            client_version = request.headers.get("x-insightflow-client-version", "")[:80]
            fingerprint = hashlib.sha256(
                f"{error_type or ''}:{error_message or ''}".encode("utf-8", "replace")
            ).hexdigest() if error_type else None
            try:
                with SessionLocal.begin() as db:
                    db.execute(text("""
                        INSERT INTO platform_backend_events
                          (event_id, request_id, method, route, status_code, duration_ms,
                           principal_id, client_version, error_type, error_message, error_stack, error_fingerprint)
                        VALUES
                          (:id, :request_id, :method, :route, :status, :duration,
                           (SELECT principal_id FROM identity_bindings
                            WHERE provider='supabase' AND provider_subject=:subject
                              AND status='active' LIMIT 1),
                           :client_version, :error_type, :error_message, :error_stack, :fingerprint)
                    """), {
                        "id": "bevt_" + uuid.uuid4().hex,
                        "request_id": request_id,
                        "method": request.method[:12],
                        "route": route,
                        "status": status_code,
                        "duration": duration_ms,
                        "subject": subject,
                        "client_version": client_version or None,
                        "error_type": error_type,
                        "error_message": error_message,
                        "error_stack": error_stack,
                        "fingerprint": fingerprint,
                    })
            except Exception:
                logger.exception("backend_observability_persist_failed request_id=%s", request_id)
