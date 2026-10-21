from pathlib import Path


PROVIDER = Path("firebase_authz/supabase_provider.py").read_text()


def _function_source(name: str, next_name: str) -> str:
    start = PROVIDER.index(f"def {name}(")
    end = PROVIDER.index(f"\ndef {next_name}(", start)
    return PROVIDER[start:end]


def test_invitation_creation_requires_active_branch_head_assignment():
    source = _function_source("create_invitation", "pending_invitations")
    assert "role_id='branch_head'" in source
    assert "location_id=:location AND role_id='branch_head'" in source
    assert "status='active'" in source
    assert "Only an active Branch Head assigned to this branch" in source


def test_lower_level_assignments_do_not_derive_branch_head_invitation_scope():
    source = _function_source("create_invitation", "pending_invitations")
    branch_resolution = source.split("actor_location_rows = db.execute", 1)[1].split(".scalars().all()", 1)[0]
    assert "role_id='branch_head'" in branch_resolution


def test_invitation_acceptance_cannot_reactivate_suspended_or_removed_membership():
    source = _function_source("accept_invitation", "mark_invitation_password_setup")
    assert 'SELECT employee_id, status FROM organization_members' in source
    assert '"suspended", "removed", "revoked", "inactive", "disabled"' in source
    assert "cannot be reactivated by an invitation" in source
    assert "FOR UPDATE" in source


def test_invitation_acceptance_keeps_invitation_role_server_authoritative():
    source = _function_source("accept_invitation", "mark_invitation_password_setup")
    assert 'invitation["role_id"]' in source
    assert 'invitation["location_id"]' in source
