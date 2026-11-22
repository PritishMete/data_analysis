import asyncio

from sqlalchemy import create_engine

from security_hardening import DatabaseRateLimiter, OriginProtectionMiddleware, RequestSizeLimitMiddleware, SecurityHeadersMiddleware


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


def _run_origin_request(method, headers):
    downstream_called = False
    sent = []

    async def downstream(scope, receive, send):
        nonlocal downstream_called
        downstream_called = True
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http",
        "method": method,
        "path": "/v1/managed-datasets",
        "headers": headers,
        "client": ("192.0.2.10", 5000),
    }
    asyncio.run(OriginProtectionMiddleware(downstream)(scope, receive, send))
    return downstream_called, sent[0]["status"]


def test_origin_protection_rejects_disallowed_cross_origin_mutations(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_CORS_ORIGINS", "https://app.example.test")
    called, status = _run_origin_request(
        "POST", [(b"origin", b"https://attacker.example")]
    )
    assert called is False
    assert status == 403


def test_origin_protection_allows_configured_origin_mutations(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_CORS_ORIGINS", "https://app.example.test")
    called, status = _run_origin_request(
        "POST", [(b"origin", b"https://app.example.test")]
    )
    assert called is True
    assert status == 204


def test_cookie_authenticated_mutation_requires_origin(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_CORS_ORIGINS", "https://app.example.test")
    called, status = _run_origin_request("POST", [(b"cookie", b"session=opaque")])
    assert called is False
    assert status == 403


def test_bearer_authenticated_mutation_without_cookie_is_not_cookie_csrf(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_CORS_ORIGINS", "https://app.example.test")
    called, status = _run_origin_request(
        "POST", [(b"authorization", b"Bearer opaque")]
    )
    assert called is True
    assert status == 204


def test_safe_get_does_not_use_origin_csrf_gate(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_CORS_ORIGINS", "https://app.example.test")
    called, status = _run_origin_request(
        "GET", [(b"origin", b"https://attacker.example")]
    )
    assert called is True
    assert status == 204
