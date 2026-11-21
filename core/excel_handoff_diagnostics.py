from __future__ import annotations

import logging
from datetime import datetime, timezone
from uuid import uuid4

logger = logging.getLogger(__name__)


def new_correlation_id() -> str:
    return f"auth-{uuid4().hex}"


def event(operation: str, *, correlation_id: str, success: bool,
          status: int | None = None, exception_class: str | None = None,
          category: str | None = None) -> None:
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
    logger.info("excel_auth_diagnostic %s", fields)
