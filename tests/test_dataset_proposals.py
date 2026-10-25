from pathlib import Path
from contextlib import contextmanager
from datetime import datetime, timezone
from types import SimpleNamespace
import io

import pytest


def test_proposal_migration_keeps_candidate_private_until_review():
    migration = Path("migrations/0034_dataset_change_proposals.sql").read_text(encoding="utf-8")
    assert "ENABLE ROW LEVEL SECURITY" in migration
    assert "dataset.propose" in migration
    assert "CHECK (status IN ('pending', 'approved', 'rejected', 'stale'))" in migration
    assert "candidate_version_pk" in migration
    assert "fk_dataset_change_proposal_branch" in migration
    assert "uq_dataset_change_pending_content" in migration


def test_new_dataset_proposal_and_grant_revocation_are_server_enforced():
    proposals = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    grants = Path("dataset_storage/manager_grants.py").read_text(encoding="utf-8")
    routes = Path("dataset_storage/routes.py").read_text(encoding="utf-8")
    migration = Path("migrations/0035_branch_scoped_manager_upload_grants.sql").read_text(encoding="utf-8")
    assert 'dataset_id: str | None' in proposals
    assert 'dataset_kind": "new" if is_new else "existing"' in proposals
    assert 'expected_current_version_id=(None if is_new else str(proposal["base_version_id"]))' in proposals
    assert "revoked_at IS NULL" in proposals
    assert "create_manager_upload_grant" in routes
    assert "revoke_manager_upload_grant" in routes
    assert "FOR UPDATE" in grants
    assert "DELETE FROM role_permissions" in migration
    assert "ALTER COLUMN base_version_id DROP NOT NULL" in migration
    assert "dataset_authorization" in proposals


def test_postgres_integration_suite_covers_rollback_concurrency_and_revocation_race():
    source = Path("tests/integration/test_postgres_manager_grant_races.py").read_text(encoding="utf-8")
    assert "test_postgres_first_publication_and_audit_are_one_transaction" in source
    assert "test_postgres_concurrent_approval_allows_only_one_decision" in source
    assert "test_postgres_revocation_wins_before_approval_revalidates_grant" in source
    assert "INSIGHTFLOW_TEST_POSTGRES_URL" in source


def test_proposal_approval_uses_transactional_finalization_and_base_guard():
    source = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert 'expected_current_version_id=(None if is_new else str(proposal["base_version_id"]))' in source
    assert "commit=False" in source
    assert "FOR UPDATE" in source
    assert "A Branch Head cannot review their own proposal." in source


def test_manager_submission_requires_persistent_branch_scoped_grant_not_role_permission():
    source = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    migration = Path("migrations/0035_branch_scoped_manager_upload_grants.sql").read_text(encoding="utf-8")
    assert 'role_id="manager"' in source
    assert "_active_manager_grant(" in source
    assert "manager_dataset_upload_grants" in source
    assert "DELETE FROM role_permissions" in migration
    assert "uq_manager_upload_grant_active" in migration
    assert "revoked_at IS NULL" in migration


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


def test_proposal_duplicate_does_not_touch_official_dataset_metadata():
    source = Path("datasets/service.py").read_text(encoding="utf-8")
    duplicate = source.split("if current is not None and current.file_hash == file_hash:", 1)[1].split("expected_columns =", 1)[0]
    assert "if candidate_version_id is None:" in duplicate
    assert "self.repository.touch_last_accessed(existing.dataset_id)" in duplicate


def test_publication_paths_revalidate_branch_scope_under_lock():
    managed = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    proposals = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert "FOR SHARE" in managed
    assert "original dataset branch assignment changed during upload." in managed
    assert "FOR UPDATE" in proposals
    assert "original dataset branch assignment changed after submission." in proposals.lower()


def test_publication_lock_order_serializes_dataset_scope_and_assignment():
    managed = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    proposals = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    assert managed.index("SELECT dataset_id FROM datasets") < managed.index("_lock_active_upload_assignment(repo, context)")
    assert proposals.index('select(Dataset).where(Dataset.dataset_id == proposal["dataset_id"])') < proposals.index('principal_id=principal_id, location_id=str(proposal["location_id"])')

class _Result:
    def __init__(self, *, row=None, scalar=None):
        self.row = row
        self.scalar = scalar

    def mappings(self):
        return self

    def first(self):
        return self.row

    def scalar_one_or_none(self):
        return self.scalar


class _ProposalSession:
    def __init__(self, dataset, candidate, proposal=None, *, fail_audit=False):
        self.dataset = dataset
        self.candidate = candidate
        self.proposal = proposal
        self.fail_audit = fail_audit
        self.inserted_proposal = False
        self.audit_count = 0
        self.commits = 0
        self.closed = False

    @contextmanager
    def begin(self):
        dataset_snapshot = dict(vars(self.dataset))
        candidate_snapshot = dict(vars(self.candidate))
        proposal_snapshot = dict(self.proposal) if self.proposal is not None else None
        try:
            yield self
        except Exception:
            vars(self.dataset).clear()
            vars(self.dataset).update(dataset_snapshot)
            vars(self.candidate).clear()
            vars(self.candidate).update(candidate_snapshot)
            if self.proposal is not None and proposal_snapshot is not None:
                self.proposal.clear()
                self.proposal.update(proposal_snapshot)
            raise

    def execute(self, statement, params=None):
        sql = str(statement)
        params = params or {}
        if "SELECT * FROM dataset_change_proposals" in sql:
            return _Result(row=self.proposal)
        if "FROM manager_dataset_upload_grants g" in sql:
            return _Result(scalar="grant-1")
        if "SELECT location_id, status, protected_original" in sql:
            return _Result(row={"location_id": "branch-1", "status": "active", "protected_original": True})
        if "SELECT oa.assignment_id" in sql:
            return _Result(scalar="assignment-active")
        if "FROM datasets" in sql:
            return _Result(scalar=self.dataset)
        if "INSERT INTO dataset_change_proposals" in sql:
            self.inserted_proposal = True
            return _Result()
        if "UPDATE dataset_change_proposals" in sql:
            if self.proposal is not None:
                if "status='approved'" in sql:
                    self.proposal["status"] = "approved"
                elif "status='rejected'" in sql:
                    self.proposal["status"] = "rejected"
                elif "status='stale'" in sql:
                    self.proposal["status"] = "stale"
            return _Result()
        if "INSERT INTO audit_events" in sql:
            if self.fail_audit:
                raise RuntimeError("simulated audit persistence failure")
            self.audit_count += 1
            return _Result()
        return _Result()

    def get(self, model, key):
        return self.candidate if key == self.candidate.version_pk else None

    def flush(self):
        return None

    def commit(self):
        self.commits += 1

    def rollback(self):
        return None

    def close(self):
        self.closed = True


class _ProposalRepository:
    def __init__(self, db, dataset, candidate):
        self.db = db
        self.dataset = dataset
        self.candidate = candidate

    def get_by_id(self, dataset_id):
        return self.dataset if dataset_id == self.dataset.dataset_id else None

    def get_version(self, dataset_id, version_id):
        if dataset_id == self.dataset.dataset_id and version_id == self.candidate.version_id:
            return self.candidate
        return None


def _fixture_dataset_and_candidate():
    dataset = SimpleNamespace(
        dataset_id="dataset-1", organization_id="org-1", dataset_name="Finance",
        status="ready", current_version_id="v1", version_number=1,
        schema_hash="old-schema", file_hash="old-hash", row_count=2,
        column_count=1, original_filename="official.csv", content_type="text/csv",
        file_size=20, storage_provider=None, storage_object_id=None, last_accessed=None,
    )
    candidate = SimpleNamespace(
        version_pk="candidate-pk", dataset_id="dataset-1", version_id="p-candidate",
        status="processing", version_number=2, schema_hash="new-schema",
        file_hash="a" * 64, row_count=3, column_count=1,
        original_filename="proposed.csv", content_type="text/csv", file_size=30,
        storage_provider=None, storage_object_id=None, created_at=datetime.now(timezone.utc),
    )
    return dataset, candidate


def _proposal_row():
    return {
        "proposal_id": "proposal-1", "organization_id": "org-1",
        "workspace_id": "workspace-1", "dataset_id": "dataset-1",
        "location_id": "branch-1", "candidate_version_pk": "candidate-pk",
        "candidate_version_id": "p-candidate", "submitted_by_principal_id": "manager-1",
        "base_version_id": "v1", "dataset_kind": "existing", "upload_grant_id": "grant-1",
        "status": "pending", "original_filename": "proposed.csv",
        "file_size": 30, "file_hash": "a" * 64, "decision_note": None,
    }


def _patch_proposal_auth(monkeypatch, *, role, principal_id):
    import dataset_storage.proposals as proposals

    monkeypatch.setattr(proposals, "_claims", lambda token: {
        "uid": principal_id, "sub": principal_id, "provider": "supabase",
    })
    monkeypatch.setattr(proposals, "_authorization_context", lambda claims, workspace: {
        "workspace_authorized": True, "workspace_id": "workspace-1",
        "organization_id": "org-1", "principal_id": principal_id,
        "role_ids": [role], "permissions": ["dataset.propose"] if role == "manager" else [],
    })
    monkeypatch.setattr(proposals, "authorize_dataset", lambda *args, **kwargs: {
        "protected_original": True, "location_id": "branch-1",
    })
    monkeypatch.setattr(proposals, "_safe_filename", lambda value: value)
    return proposals


def test_manager_submission_keeps_official_pointer_and_metadata_unchanged(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    session = _ProposalSession(dataset, candidate)
    repository = _ProposalRepository(session, dataset, candidate)
    registration = SimpleNamespace(
        registration=SimpleNamespace(dataset=dataset, was_duplicate=False),
        version=candidate,
    )
    _patch_proposal_auth(monkeypatch, role="manager", principal_id="manager-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    class _Registry:
        def __init__(self, repo):
            pass

        def register_csv_stream(self, **kwargs):
            assert kwargs["candidate_version_id"].startswith("p")
            return registration

    monkeypatch.setattr(proposals, "DatasetRegistryService", _Registry)
    original_metadata = (dataset.current_version_id, dataset.version_number, dataset.file_hash, dataset.row_count)

    result = proposals.submit_dataset_proposal(
        workspace_id="workspace-1", token="test-token", dataset_id="dataset-1",
        filename="proposed.csv", stream=io.BytesIO(b"a,b\n1,2\n"),
        content_type="text/csv",
    )

    assert result["status"] == "pending"
    assert session.inserted_proposal
    assert session.audit_count == 1
    assert candidate.status == "processing"
    assert (dataset.current_version_id, dataset.version_number, dataset.file_hash, dataset.row_count) == original_metadata


def test_branch_head_approval_publishes_candidate_and_audits_atomically(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    proposal = _proposal_row()
    session = _ProposalSession(dataset, candidate, proposal)
    repository = _ProposalRepository(session, dataset, candidate)
    _patch_proposal_auth(monkeypatch, role="branch_head", principal_id="branch-head-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    result = proposals.decide_dataset_proposal(
        workspace_id="workspace-1", token="test-token", proposal_id="proposal-1",
        approve=True, decision_note="Reviewed",
    )

    assert result["status"] == "approved"
    assert dataset.current_version_id == "p-candidate"
    assert candidate.status == "ready"
    assert proposal["status"] == "approved"
    assert session.audit_count == 1
    assert session.commits == 0


def test_audit_failure_rolls_back_candidate_publication(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    proposal = _proposal_row()
    session = _ProposalSession(dataset, candidate, proposal, fail_audit=True)
    repository = _ProposalRepository(session, dataset, candidate)
    _patch_proposal_auth(monkeypatch, role="branch_head", principal_id="branch-head-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    with pytest.raises(RuntimeError, match="audit persistence failure"):
        proposals.decide_dataset_proposal(
            workspace_id="workspace-1", token="test-token", proposal_id="proposal-1",
            approve=True,
        )

    assert dataset.current_version_id == "v1"
    assert candidate.status == "processing"
    assert proposal["status"] == "pending"


def test_self_approval_is_denied(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    proposal = _proposal_row()
    proposal["submitted_by_principal_id"] = "branch-head-1"
    session = _ProposalSession(dataset, candidate, proposal)
    repository = _ProposalRepository(session, dataset, candidate)
    _patch_proposal_auth(monkeypatch, role="branch_head", principal_id="branch-head-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    with pytest.raises(proposals.PermissionDenied, match="cannot review their own proposal"):
        proposals.decide_dataset_proposal(
            workspace_id="workspace-1", token="test-token", proposal_id="proposal-1",
            approve=True,
        )


def test_rejection_preserves_official_pointer_and_records_decision(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    proposal = _proposal_row()
    session = _ProposalSession(dataset, candidate, proposal)
    repository = _ProposalRepository(session, dataset, candidate)
    _patch_proposal_auth(monkeypatch, role="branch_head", principal_id="branch-head-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    result = proposals.decide_dataset_proposal(
        workspace_id="workspace-1", token="test-token", proposal_id="proposal-1",
        approve=False, decision_note="Schema does not match policy",
    )

    assert result["status"] == "rejected"
    assert dataset.current_version_id == "v1"
    assert candidate.status == "processing"
    assert proposal["status"] == "rejected"
    assert session.audit_count == 1


def test_stale_proposal_cannot_publish_candidate(monkeypatch):
    import dataset_storage.proposals as proposals

    dataset, candidate = _fixture_dataset_and_candidate()
    dataset.current_version_id = "v2"
    proposal = _proposal_row()
    session = _ProposalSession(dataset, candidate, proposal)
    repository = _ProposalRepository(session, dataset, candidate)
    _patch_proposal_auth(monkeypatch, role="branch_head", principal_id="branch-head-1")
    monkeypatch.setattr(proposals, "SessionLocal", lambda: session)
    monkeypatch.setattr(proposals, "DatasetRepository", lambda db: repository)

    result = proposals.decide_dataset_proposal(
        workspace_id="workspace-1", token="test-token", proposal_id="proposal-1",
        approve=True,
    )

    assert result["status"] == "stale"
    assert dataset.current_version_id == "v2"
    assert candidate.status == "processing"
    assert proposal["status"] == "stale"
    assert session.audit_count == 1


def test_proposal_candidate_versions_use_nonpublished_identifiers():
    source = Path("datasets/service.py").read_text(encoding="utf-8")
    assert "candidate_version_id: str | None = None" in source
    assert 'version_id=candidate_version_id or f"v{version_number}"' in source


def test_legacy_ingestion_cannot_bypass_branch_head_upload_authorization():
    source = Path("ingestion/routes.py").read_text(encoding="utf-8")
    assert "_authorize_upload(claims, resolved_workspace)" in source
    assert "require_email_verified(verify_id_token(token))" in source
    assert "does not match the authenticated workspace" in source


def test_manager_cannot_delete_original_dataset_directly():
    source = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    start = source.index("def delete_managed_dataset(")
    end = source.index("\ndef create_managed_working_copy(", start)
    delete_service = source[start:end]
    assert '"branch_head" not in set(context.get("role_ids", []))' in delete_service
    assert "authorize_dataset_upload_scope" in delete_service


def test_production_release_branch_and_render_service_are_aligned():
    render = Path("render.yaml").read_text(encoding="utf-8")
    workflow = Path(".github/workflows/production-authz-migrations.yml").read_text(encoding="utf-8")
    assert "name: data_analysis" in render
    assert "branch: feature/employee-management-cell" in render
    assert "workflow_dispatch:" in workflow
    assert "  push:" not in workflow
    assert "environment: production" in workflow
    assert "concurrency:" in workflow
    assert "feature/data-workspace" not in workflow
    assert "github.ref == 'refs/heads/feature/employee-management-cell'" in workflow
    smoke = Path(".github/workflows/production-backend-smoke.yml").read_text(encoding="utf-8")
    smoke_triggers = smoke.split("jobs:", 1)[0]
    assert "workflow_dispatch:" in smoke_triggers
    assert "push:" not in smoke_triggers
    assert "refs/heads/feature/employee-management-cell" in smoke


def test_health_readiness_is_gated_by_successful_database_initialization():
    source = Path("main.py").read_text(encoding="utf-8")
    startup = source.split("def _initialize_production_database() -> None:", 1)[1].split(
        "app.add_event_handler(\"startup\", _initialize_production_database)", 1
    )[0]
    health = source.split('@app.get("/health")', 1)[1].split(
        '@app.get("/v1/build-info")', 1
    )[0]
    assert "_run_production_authz_migrations()" in startup
    assert "init_db()" in startup
    assert startup.index("_run_production_authz_migrations()") < startup.index("init_db()")
    assert startup.index("init_db()") < startup.index("_PRODUCTION_READY = True")
    assert "if not _PRODUCTION_READY:" in health
    assert "status_code=503" in health
    assert '"database_ready": True' in health



def test_release_ci_tracks_the_active_render_branch_and_not_historical_feature_branches():
    workflow = Path(".github/workflows/insightflow-backend-ci.yml").read_text(encoding="utf-8")
    triggers = workflow.split("jobs:", 1)[0]
    assert "branches: [main, feature/employee-management-cell]" in triggers
    assert "feature/data-workspace" not in triggers
    assert "fix/protected-original-upload-grant-20261025" not in triggers


def test_release_process_documents_manual_render_and_production_migration_controls():
    guide = Path("RELEASE_PROCESS.md").read_text(encoding="utf-8")
    assert "feature/employee-management-cell" in guide
    assert "Auto-deploy is disabled" in guide
    assert "main" in guide
    assert "manual" in guide.lower()
    workflow = Path(".github/workflows/production-authz-migrations.yml").read_text(encoding="utf-8")
    assert "workflow_dispatch:" in workflow
    assert "  push:" not in workflow
    assert "environment: production" in workflow
