import asyncio

from sqlalchemy import create_engine

from security_hardening import DatabaseRateLimiter, RequestSizeLimitMiddleware, SecurityHeadersMiddleware


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


def _security_response_headers(monkeypatch, env, hsts):
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    if hsts is None:
        monkeypatch.delenv("INSIGHTFLOW_HSTS_ENABLED", raising=False)
    else:
        monkeypatch.setenv("INSIGHTFLOW_HSTS_ENABLED", hsts)

    async def downstream(scope, receive, send):
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"application/json")],
        })
        await send({"type": "http.response.body", "body": b"{}"})

    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "method": "GET", "path": "/health", "headers": [], "client": ("127.0.0.1", 1)}
    asyncio.run(SecurityHeadersMiddleware(downstream)(scope, receive, send))
    return dict(sent[0]["headers"])


def test_security_headers_are_present_without_implicitly_enabling_hsts(monkeypatch):
    headers = _security_response_headers(monkeypatch, {"INSIGHTFLOW_ENV": "test"}, None)
    assert headers[b"x-content-type-options"] == b"nosniff"
    assert headers[b"x-frame-options"] == b"DENY"
    assert headers[b"referrer-policy"] == b"strict-origin-when-cross-origin"
    assert headers[b"content-security-policy"] == b"default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    assert headers[b"cross-origin-resource-policy"] == b"same-origin"
    assert headers[b"cross-origin-opener-policy"] == b"same-origin"
    assert b"strict-transport-security" not in headers


def test_hsts_requires_explicit_production_opt_in(monkeypatch):
    disabled = _security_response_headers(monkeypatch, {"INSIGHTFLOW_ENV": "production"}, "false")
    assert b"strict-transport-security" not in disabled
    enabled = _security_response_headers(monkeypatch, {"INSIGHTFLOW_ENV": "production"}, "true")
    assert enabled[b"strict-transport-security"] == b"max-age=31536000; includeSubDomains"


def test_hsts_is_never_enabled_by_flag_outside_production(monkeypatch):
    headers = _security_response_headers(monkeypatch, {"INSIGHTFLOW_ENV": "test"}, "true")
    assert b"strict-transport-security" not in headers
