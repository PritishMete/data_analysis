from pathlib import Path


def test_proposal_migration_keeps_candidate_private_until_review():
    migration = Path("migrations/0034_dataset_change_proposals.sql").read_text(encoding="utf-8")
    assert "ENABLE ROW LEVEL SECURITY" in migration
    assert "dataset.propose" in migration
    assert "CHECK (status IN ('pending', 'approved', 'rejected', 'stale'))" in migration
    assert "candidate_version_pk" in migration
    assert "fk_dataset_change_proposal_branch" in migration
    assert "uq_dataset_change_pending_content" in migration


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


def test_legacy_ingestion_cannot_publish_without_branch_head_authorization():
    source = Path("ingestion/routes.py").read_text(encoding="utf-8")
    assert "authorization: str = Header(default=None)" in source
    assert "_authorize_upload(claims, resolved_workspace)" in source
    assert 'organization_id=str(context["organization_id"])' in source
    assert 'uploaded_by=str(context["principal_id"])' in source
    assert "The supplied organization does not match the authenticated workspace." in source


def test_duplicate_pending_proposal_content_is_constrained():
    migration = Path("migrations/0034_dataset_change_proposals.sql").read_text(encoding="utf-8")
    service = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert "uq_dataset_change_pending_content" in migration
    assert "An identical proposal is already pending for this dataset version." in service
    assert "provider_subject=:provider_subject" in service
