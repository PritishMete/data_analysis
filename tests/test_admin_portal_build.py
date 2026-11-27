import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "apps" / "admin_portal"


def run_build(**values):
    env = os.environ.copy()
    for key in ("ADMIN_PORTAL_ENV", "INSIGHTFLOW_ADMIN_API", "INSIGHTFLOW_SUPABASE_URL", "INSIGHTFLOW_SUPABASE_ANON_KEY", "INSIGHTFLOW_SUPABASE_SERVICE_ROLE_KEY"):
        env.pop(key, None)
    env.update(values)
    return subprocess.run(["node", "build.mjs"], cwd=ROOT, env=env, capture_output=True, text=True)


def test_production_build_writes_public_configuration_and_exact_pages_origins():
    result = run_build(ADMIN_PORTAL_ENV="production", INSIGHTFLOW_ADMIN_API="https://api.example.test", INSIGHTFLOW_SUPABASE_URL="https://project.supabase.co", INSIGHTFLOW_SUPABASE_ANON_KEY="public-key")
    assert result.returncode == 0, result.stderr
    config = (ROOT / "dist" / "config.js").read_text()
    payload = json.loads(config.split("=", 1)[1].rstrip(";"))
    assert payload == {"apiOrigin": "https://api.example.test", "supabaseUrl": "https://project.supabase.co", "supabaseAnonKey": "public-key"}
    assert "service_role" not in config.lower()

    headers_path = ROOT / "dist" / "_headers"
    assert headers_path.is_file(), "Cloudflare Pages _headers must be present in the output directory"
    headers = headers_path.read_text()
    assert "https://api.example.test" in headers
    assert "https://project.supabase.co" in headers
    assert "https://*.supabase.co" not in headers
    assert "__INSIGHTFLOW_ADMIN_API_ORIGIN__" not in headers
    assert "__INSIGHTFLOW_SUPABASE_ORIGIN__" not in headers
    assert "https://*.onrender.com" not in headers
    assert "object-src 'none'" in headers
    assert "frame-ancestors 'none'" in headers


def test_build_rejects_missing_or_unsupported_environment():
    assert run_build().returncode != 0
    assert "ADMIN_PORTAL_ENV" in run_build(ADMIN_PORTAL_ENV="staging").stderr


def test_production_requires_all_values_and_https_origins():
    base = {"ADMIN_PORTAL_ENV": "production", "INSIGHTFLOW_ADMIN_API": "https://api.example.test", "INSIGHTFLOW_SUPABASE_URL": "https://project.supabase.co", "INSIGHTFLOW_SUPABASE_ANON_KEY": "key"}
    for missing in ("INSIGHTFLOW_ADMIN_API", "INSIGHTFLOW_SUPABASE_URL", "INSIGHTFLOW_SUPABASE_ANON_KEY"):
        values = dict(base); values.pop(missing)
        assert run_build(**values).returncode != 0
    for key in ("INSIGHTFLOW_ADMIN_API", "INSIGHTFLOW_SUPABASE_URL"):
        values = dict(base); values[key] = "http://insecure.example"
        assert run_build(**values).returncode != 0
    values = dict(base); values["INSIGHTFLOW_ADMIN_API"] = "https://user:pass@example.test/path?q=1"
    assert run_build(**values).returncode != 0
    values = dict(base); values["INSIGHTFLOW_ADMIN_API"] = "https://api.example.test/api"
    assert run_build(**values).returncode != 0
    values = dict(base); values["INSIGHTFLOW_SUPABASE_URL"] = "https://project.supabase.co/auth/v1"
    assert run_build(**values).returncode != 0


def test_development_requires_explicit_mode_and_allows_local_api():
    result = run_build(ADMIN_PORTAL_ENV="development", INSIGHTFLOW_ADMIN_API="http://localhost:8000")
    assert result.returncode == 0, result.stderr
    headers = (ROOT / "dist" / "_headers").read_text()
    assert "http://localhost:8000" in headers
    assert "__INSIGHTFLOW_SUPABASE_ORIGIN__" not in headers


def test_server_secret_variable_is_rejected():
    result = run_build(ADMIN_PORTAL_ENV="test", INSIGHTFLOW_SUPABASE_SERVICE_ROLE_KEY="server-secret")
    assert result.returncode != 0


def teardown_module():
    shutil.rmtree(ROOT / "dist", ignore_errors=True)
