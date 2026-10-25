from pathlib import Path


def test_manager_direct_original_import_is_fail_closed():
    source = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    gate = source.split("def _authorize_upload(", 1)[1].split("\n\ndef _authorize_delete", 1)[0]
    assert '"branch_head" not in roles' in gate
    assert "Managers must submit changes for Branch Head review" in gate


def test_original_write_grants_are_not_delegable():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    grant_fn = source.split("def set_dataset_grant(", 1)[1].split("\n\ndef ", 1)[0]
    assert 'allowed = {"dataset.create_working_copy"}' in grant_fn
    assert "dataset.upload_original" not in grant_fn


def test_original_write_and_delete_require_branch_head_scope():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    auth_fn = source.split("def authorize_dataset(", 1)[1].split("\n\ndef set_dataset_grant", 1)[0]
    assert 'if "branch_head" not in actor_roles:' in auth_fn
    assert 'elif action in {"dataset.delete", "dataset.share", "dataset.manage_acl"}:' in auth_fn
