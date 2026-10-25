from pathlib import Path


def test_proposal_migration_keeps_candidate_private_until_review():
    migration = Path("migrations/0034_dataset_change_proposals.sql").read_text(encoding="utf-8")
    assert "ENABLE ROW LEVEL SECURITY" in migration
    assert "dataset.propose" in migration
    assert "CHECK (status IN ('pending', 'approved', 'rejected', 'stale'))" in migration
    assert "candidate_version_pk" in migration


def test_proposal_approval_uses_transactional_finalization_and_base_guard():
    source = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert "expected_current_version_id=str(proposal[\"base_version_id\"])" in source
    assert "commit=False" in source
    assert "FOR UPDATE" in source
    assert "A Branch Head cannot review their own proposal." in source


def test_manager_submission_requires_current_branch_assignment_and_permission():
    source = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert 'role_id="manager"' in source
    assert "require_proposal_permission=True" in source
    assert '"dataset.propose" not in set(context.get("permissions", []))' in source
