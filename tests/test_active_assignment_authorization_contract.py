from pathlib import Path


def test_management_permissions_require_active_scope_for_operational_roles():
    source = Path("firebase_authz/management_domain.py").read_text(encoding="utf-8")
    permission_query = source.split("def _permissions(", 1)[1].split("\ndef _is_org_manager", 1)[0]

    # Role catalogue rows are not authority by themselves. Every permission
    # must join to a current active assignment and valid scope.
    assert "JOIN organizational_assignments oa" in permission_query
    assert "oa.status='active'" in permission_query
    assert "oa.role_id='organization_owner'" in permission_query
    assert "oa.location_id IS NOT NULL" in permission_query
    assert "l.status='active'" in permission_query
    assert "s.location_id=oa.location_id" in permission_query
    assert "oa.role_id <> 'team_lead'" in permission_query
    assert "oa.section_id IS NOT NULL AND s.status='active'" in permission_query


def test_manager_replacement_deactivates_assignment_and_sensitive_proposal_paths_revalidate():
    management = Path("firebase_authz/management_domain.py").read_text(encoding="utf-8")
    proposals = Path("dataset_storage/proposals.py").read_text(encoding="utf-8")

    replacement = management.split("def replace_manager(", 1)[1].split("\ndef request_team_lead_assignment", 1)[0]
    assert "SET status='inactive', updated_at=now()" in replacement
    assert "INSERT INTO organizational_assignments" in replacement

    # A stale manager role cannot substitute for an active assignment at
    # submission time; Branch Head decisions revalidate their exact branch.
    assert 'role_id="manager"' in proposals
    assert "require_proposal_permission=True" in proposals
    assert 'role_id="branch_head"' in proposals
    assert "provider_subject=provider_subject" in proposals
    assert "A Branch Head cannot review their own proposal." in proposals
