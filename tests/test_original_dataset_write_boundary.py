from pathlib import Path


def test_manager_original_writes_are_proposal_only():
    service = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    proposals = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")
    gate = service.split("def _authorize_upload(", 1)[1].split("\n\ndef _authorize_delete", 1)[0]
    upload_scope = provider.split("def authorize_dataset_upload_scope(", 1)[1].split("\n\ndef _has_active_branch_assignment", 1)[0]
    assert '"organization_owner", "branch_head"' in gate
    assert "Managers must submit a proposal for Branch Head review." in gate
    assert "manager_dataset_upload_grants" not in upload_scope
    assert "def submit_dataset_proposal(" in proposals
    assert "def decide_dataset_proposal(" in proposals
    assert 'if "branch_head" not in set(context.get("role_ids", []))' in proposals


def test_original_write_grants_are_not_delegable():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    grant_fn = source.split("def set_dataset_grant(", 1)[1].split("\n\ndef ", 1)[0]
    assert 'allowed = {"dataset.create_working_copy"}' in grant_fn
    assert "original-write delegation is forbidden" in grant_fn


def test_original_write_and_delete_require_branch_head_scope():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    auth_fn = source.split("def authorize_dataset(", 1)[1].split("\n\ndef set_dataset_grant", 1)[0]
    assert 'if "branch_head" not in actor_roles:' in auth_fn
    assert 'elif action in {"dataset.delete", "dataset.share", "dataset.manage_acl"}:' in auth_fn

def test_copy_request_rejection_uses_only_bound_sql_parameters_and_pending_state():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    decision = source.split("def approve_copy_request(", 1)[1].split("\n\ndef assign_working_copy", 1)[0]
    rejection = decision.split("if not approve:", 1)[1].split("return {\"request_id\": request_id, \"status\": \"rejected\"}", 1)[0]
    assert "WHERE organization_id=:org AND request_id=:request AND status='pending'" in rejection
    assert '"org": org' in rejection
    assert '"reviewer": context["principal_id"]' in rejection
    assert '"request": request_id' in rejection
    assert '"requester": request_id' not in rejection

