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


def _function_body(source: str, name: str) -> str:
    start = source.index(f"def {name}(")
    next_def = source.find(chr(10) + "def ", start + 1)
    return source[start: next_def if next_def >= 0 else len(source)]


def test_legacy_membership_and_approval_mutations_require_active_management_scope():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    membership = _function_body(source, "set_membership_status")
    approval = _function_body(source, "set_approved_employee")
    role_mutation = _function_body(source, "mutate_role")

    for body in (membership, approval, role_mutation):
        assert "_active_assigned_role_rows" in body
        assert 'actor["status"] != "active"' in body

    assert 'actor_roles.intersection({"organization_owner", "branch_head"})' in membership
    assert 'actor_roles.intersection({"organization_owner", "branch_head"})' in approval
    assert '"membership.manage"' not in membership
    assert '"membership.manage"' not in approval
    assert "You cannot change roles for an equal or higher role." in role_mutation


def test_legacy_delegations_are_branch_scoped_and_copy_only():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    delegation = _function_body(source, "set_delegation")

    assert 'allowed = {"dataset.create_working_copy"}' in delegation
    assert "Only an active Organization Owner or Branch Head can manage delegations." in delegation
    assert "The Team Lead is outside your branch." in delegation
    assert "A delegation member is outside your branch." in delegation
    assert "A delegated dataset is outside your branch." in delegation
    assert "_active_assigned_role_rows" in delegation


def test_manager_role_gets_only_narrow_section_and_team_lead_request_permissions():
    schema = Path("firebase_authz/schema.py").read_text(encoding="utf-8")
    migration = Path("migrations/0036_management_permission_scope_hardening.sql").read_text(encoding="utf-8")
    domain = Path("firebase_authz/management_domain.py").read_text(encoding="utf-8")

    manager = schema.split('"manager": {', 1)[1].split("},", 1)[0]
    assert '"organization.section.create"' in manager
    assert '"team_lead.request"' in manager
    assert '"users.manage"' not in manager
    assert '"membership.manage"' not in manager
    assert 'manager_capability="organization.section.create"' in domain
    assert 'manager_capability="team_lead.request"' in domain
    assert "DELETE FROM role_permissions" in migration
    assert "'membership.manage'" in migration
    assert "'users.manage'" in migration


def test_resource_grants_scope_branch_heads_and_external_viewers():
    source = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    grant = _function_body(source, "set_resource_grant")
    view_authorization = _function_body(source, "authorize_dataset")

    assert "The resource belongs to a branch outside your Branch Head scope." in grant
    assert "External Viewers may receive read-only grants" in grant
    assert 'elif "external_viewer" in actor_roles:' in view_authorization
    assert "dataset.view_original" in view_authorization
