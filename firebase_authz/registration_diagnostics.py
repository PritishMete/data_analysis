"""Privacy-safe timing context for organization registration diagnostics."""

from __future__ import annotations

import logging
import time
from contextvars import ContextVar
from uuid import uuid4


logger = logging.getLogger(__name__)
_context: ContextVar[tuple[str, float] | None] = ContextVar(
    "organization_registration_diagnostics", default=None
)


def begin() -> str:
    correlation_id = f"reg-{uuid4().hex[:8]}"
    _context.set((correlation_id, time.perf_counter()))
    return correlation_id


def stage(name: str) -> None:
    context = _context.get()
    if context is None:
        return
    correlation_id, started = context
    elapsed_ms = (time.perf_counter() - started) * 1000
    logger.info(
        "organization_register stage=%s correlation_id=%s elapsed_ms=%.1f",
        name,
        correlation_id,
        elapsed_ms,
    )


def end() -> None:
    _context.set(None)
