from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from uuid import uuid4

logger = logging.getLogger(__name__)
_CORRELATION_ID = re.compile(r"^auth-[0-9a-f]{32}$")


def new_correlation_id() -> str:
    return f"auth-{uuid4().hex}"


def validate_correlation_id(value: str | None) -> str:
    return value if value and _CORRELATION_ID.fullmatch(value) else new_correlation_id()


def event(operation: str, *, correlation_id: str, success: bool,
          status: int | None = None, exception_class: str | None = None,
          category: str | None = None, duration_ms: int | None = None) -> None:
    fields = {
        "correlation_id": correlation_id,
        "operation": operation,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "success": success,
    }
    if status is not None:
        fields["status"] = status
    if exception_class is not None:
        fields["exception_class"] = exception_class
    if category is not None:
        fields["category"] = category
    if duration_ms is not None:
        fields["duration_ms"] = duration_ms
    logger.info("excel_auth_diagnostic %s", fields)
