import io
import json
import urllib.error

import pytest

from firebase_authz import supabase_auth


class _Response:
    def __init__(self, payload):
        self._payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self._payload


def test_refresh_supabase_session_returns_rotated_pair(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "test-publishable-key")
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda request, timeout: _Response({
            "access_token": "new-access-token",
            "refresh_token": "new-refresh-token",
        }),
    )

    result = supabase_auth.refresh_supabase_session("old-refresh-token")

    assert result == {
        "access_token": "new-access-token",
        "refresh_token": "new-refresh-token",
    }


def test_refresh_supabase_session_rejects_invalid_refresh_token(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "test-publishable-key")

    def fail(request, timeout):
        raise urllib.error.HTTPError(
            request.full_url, 400, "invalid refresh token", {}, io.BytesIO()
        )

    monkeypatch.setattr(supabase_auth.urllib.request, "urlopen", fail)

    with pytest.raises(supabase_auth.AuthenticationRequired):
        supabase_auth.refresh_supabase_session("old-refresh-token")


def test_refresh_supabase_session_rejects_incomplete_response(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "test-publishable-key")
    monkeypatch.setattr(
        supabase_auth.urllib.request,
        "urlopen",
        lambda request, timeout: _Response({"access_token": "new-access-token"}),
    )

    with pytest.raises(supabase_auth.SupabaseAuthUnavailable):
        supabase_auth.refresh_supabase_session("old-refresh-token")


def test_refresh_supabase_session_maps_transient_network_failure(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "test-publishable-key")

    def fail(request, timeout):
        raise OSError("network unavailable")

    monkeypatch.setattr(supabase_auth.urllib.request, "urlopen", fail)

    with pytest.raises(supabase_auth.SupabaseAuthUnavailable):
        supabase_auth.refresh_supabase_session("old-refresh-token")
