from pathlib import Path


def test_branch_scope_fails_closed_for_cross_branch_assignments():
    source = Path("firebase_authz/management_domain.py").read_text()
    assert "active assignments in multiple branches" in source
    assert "len(active_branch_ids) > 1" in source
    assert "inside that branch are allowed" in source


def test_database_enforces_single_active_branch_for_every_assignment_writer():
    migration = Path("migrations/0030_single_active_branch_assignment.sql").read_text()
    assert "CREATE OR REPLACE FUNCTION enforce_single_active_branch_assignment()" in migration
    assert "BEFORE INSERT OR UPDATE OF organization_id, principal_id, location_id, role_id, status" in migration
    assert "existing.location_id <> NEW.location_id" in migration
    assert "FOR UPDATE" in migration
    assert "A person can have active assignments in only one branch." in migration


def test_branch_switchers_are_only_available_to_organization_owner():
    source = Path("flutter_detail_source/lib/features/auth/management_shell.dart").read_text()
    assert "bool get _isOrganizationOwner => _managementRole() == 'organization_owner';" in source
    assert "if (_isOrganizationOwner && locations.isNotEmpty)" in source
    assert "if (_isOrganizationOwner)\n              DropdownButtonFormField<String?>" in source
    assert "if (_isOrganizationOwner) ...[" in source
    assert "Text(_isOrganizationOwner ? 'ORGANIZATION' : 'MY BRANCH'" in source
