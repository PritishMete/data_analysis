from pathlib import Path


ROOT = Path(__file__).parents[1]


def test_pages_workflow_pins_root_base_and_oracle_worker():
    workflow = (ROOT / ".github/workflows/flutter-web-pages.yml").read_text(encoding="utf-8")

    assert 'build web --release --no-wasm-dry-run --base-href "/"' in workflow
    assert "INSIGHTFLOW_BACKEND_URL: https://insightflow-api.jaiphotoshoot.workers.dev" in workflow
    assert 'assert_text "root Pages base href"' in workflow
    assert ".onrender\\.com" in workflow


def test_windows_pages_helper_matches_production_contract():
    helper = (ROOT / "apps/flutter_app/web/deploy.ps1").read_text(encoding="utf-8")

    assert "[string]$BaseHref = '/'," in helper
    assert "[string]$BackendUrl = $env:INSIGHTFLOW_BACKEND_URL" in helper
    assert "'INSIGHTFLOW_BACKEND_URL' = $BackendUrl" in helper
    assert "https://insightflow-api.jaiphotoshoot.workers.dev" in helper
    assert "/data_analysis/" not in helper
