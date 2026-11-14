from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "production-backend-smoke.yml"


def test_production_smoke_is_manual_and_pinned_to_release_branch():
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "workflow_dispatch:" in workflow
    assert 'refs/heads/main' in workflow
    assert 'EXPECTED_SHA="${GITHUB_SHA}"' in workflow
    assert "STALE_RENDER_BUILD" in workflow
    assert "/health" in workflow
    assert "/v1/build-info" in workflow


def test_production_smoke_checks_managed_dataset_cors_scope_headers():
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "check_preflight /v1/managed-datasets" in workflow
    assert "check_preflight /v1/managed-datasets/duplicate-check" in workflow
    assert "x-insightflow-workspace-id,x-insightflow-branch-id" in workflow
    assert "access-control-allow-origin: https://pritishmete.github.io" in workflow


def test_production_smoke_rejects_unauthenticated_dataset_access():
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "check_denied GET /v1/managed-datasets" in workflow
    assert "check_denied POST /v1/managed-datasets/duplicate-check" in workflow
    assert 'test "$status" = "401" || test "$status" = "403"' in workflow
