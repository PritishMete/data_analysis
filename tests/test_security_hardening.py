import asyncio

from sqlalchemy import create_engine

from security_hardening import DatabaseRateLimiter, RequestSizeLimitMiddleware


def _run_asgi(app, body_chunks, headers=None):
    messages = iter(
        [{"type": "http.request", "body": chunk, "more_body": i < len(body_chunks) - 1}
         for i, chunk in enumerate(body_chunks)]
    )
    sent = []

    async def receive():
        try:
            return next(messages)
        except StopIteration:
            return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http",
        "method": "POST",
        "path": "/upload",
        "headers": headers or [],
        "client": ("127.0.0.1", 5000),
    }
    asyncio.run(app(scope, receive, send))
    return sent


def test_request_size_limit_rejects_content_length_before_downstream():
    called = False

    async def downstream(scope, receive, send):
        nonlocal called
        called = True

    sent = _run_asgi(
        RequestSizeLimitMiddleware(downstream, max_bytes=3),
        [b"1234"],
        headers=[(b"content-length", b"4")],
    )

    assert called is False
    assert sent[0]["status"] == 413


def test_request_size_limit_rejects_chunked_body_without_content_length():
    async def downstream(scope, receive, send):
        raise AssertionError("oversized body reached downstream")

    sent = _run_asgi(RequestSizeLimitMiddleware(downstream, max_bytes=3), [b"12", b"34"])
    assert sent[0]["status"] == 413


def test_database_rate_limiter_returns_retry_information_and_enforces_limit():
    engine = create_engine("sqlite:///:memory:")
    limiter = DatabaseRateLimiter(engine)
    limiter.initialize()

    assert limiter.allow("test-client", 1, 60)[0] is True
    allowed, retry_after = limiter.allow("test-client", 1, 60)
    assert allowed is False
    assert retry_after >= 1
