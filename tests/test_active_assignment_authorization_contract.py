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
    assert "_active_manager_grant(" in proposals and "manager_dataset_upload_grants" in proposals
    assert 'role_id="branch_head"' in proposals
    assert "provider_subject=provider_subject" in proposals
    assert "A Branch Head cannot review their own proposal." in proposals



def test_branch_head_dataset_authorization_fails_closed_for_multiple_active_branches():
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    grants = Path("dataset_storage/manager_grants.py").read_text(encoding="utf-8")

    upload_scope = provider.split(
        "def authorize_dataset_upload_scope(", 1
    )[1].split("\ndef _has_active_branch_assignment", 1)[0]
    dataset_scope = provider.split(
        "def authorize_dataset(", 1
    )[1].split("\ndef set_dataset_grant", 1)[0]
    working_copy_scope = provider.split(
        "def authorize_working_copy(", 1
    )[1].split("\ndef list_dataset_c", 1)[0]

    assert 'upload_role == "branch_head" and len(allowed_locations) != 1' in upload_scope
    assert '"branch_head" in roles' in dataset_scope
    assert 'len(scoped_locations) != 1' in dataset_scope
    assert 'len(branch_locations) != 1 or source_location not in branch_locations' in working_copy_scope
    assert "exactly one active branch assignment to manage upload grants" in grants


def test_employee_assignment_queries_distinguish_organization_and_workspace_ids():
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    helper = provider.split(
        "def _active_assigned_role_rows_for_scope(", 1
    )[1].split("\ndef _active_assigned_role_rows(", 1)[0]

    assert "WHERE oa.organization_id=:org AND m.workspace_id=:workspace" in helper
    assert '"org": organization_id, "workspace": workspace_id' in helper
    assert "db, organization_id, resolved_workspace_id, str(target[\"principal_id\"])" in provider
    assert "db, org, workspace, target_id" in provider
    assert "db, org, workspace, str(target)" in provider


def test_manager_upload_grant_is_revalidated_and_locked_through_publication():
    managed = Path("dataset_storage/service.py").read_text(encoding="utf-8")
    grants = Path("dataset_storage/manager_grants.py").read_text(encoding="utf-8")
    lock = managed.split(
        "def _lock_active_upload_assignment(", 1
    )[1].split("\ndef _physical_upload_is_complete", 1)[0]
    revoke = grants.split(
        "def revoke_manager_upload_grant(", 1
    )[1].split("\ndef list_manager_upload_grants", 1)[0]

    assert "g.revoked_at IS NULL" in lock
    assert "FOR SHARE OF g, oa, m, mr, ib, l" in lock
    assert "FOR UPDATE" in revoke
    assert "SET revoked_at=now()" in revoke
    assert "SET status='stale'" in revoke


def test_team_lead_and_employee_cannot_write_original_datasets():
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    storage = Path("dataset_storage/service.py").read_text(encoding="utf-8")

    dataset_authz = provider.split(
        "def authorize_dataset(", 1
    )[1].split("\ndef set_dataset_grant", 1)[0]
    grant_policy = provider.split(
        "def set_resource_grant(", 1
    )[1].split("\ndef register_dataset", 1)[0]

    assert 'if action in {"dataset.upload", "dataset.upload_original"}' in dataset_authz
    assert '"organization_owner" in roles or not ({"branch_head", "manager"} & roles)' in dataset_authz
    assert "Only the assigned Branch Head or an explicitly authorized Manager" in dataset_authz
    assert 'allowed_permissions = {"dataset.view_original", "dataset.create_working_copy"}' in grant_policy
    assert "Dataset grants may only provide explicit read access or copy creation." in grant_policy
    # Original-dataset writes are limited to the explicitly authorized roles;
    # the upload service must still call backend authorization for each request.
    assert 'if "organization_owner" in roles or not ({"branch_head", "manager"} & roles)' in dataset_authz
    assert 'def _authorize_upload(' in storage



def test_copy_requests_are_workspace_branch_scoped_and_review_is_single_writer():
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    request = provider.split("def request_dataset_copy(", 1)[1].split("\ndef list_copy_requests", 1)[0]
    listing = provider.split("def list_copy_requests(", 1)[1].split("\ndef approve_copy_request", 1)[0]
    decision = provider.split("def approve_copy_request(", 1)[1].split("\ndef assign_working_copy", 1)[0]

    assert "m.workspace_id=:workspace AND m.status='active'" in request
    assert "mr.role_id=oa.role_id" in request
    assert "oa.location_id=:location" in request
    assert "da.protected_original IS TRUE" in request
    assert '"organization_owner" in roles or "branch_head" not in roles' in listing
    assert "len(set(locations)) != 1" in listing
    assert "r.workspace_id=:workspace" in listing
    decision = provider.split("def approve_copy_request(", 1)[1].split("\\ndef assign_working_copy", 1)[0]
    assert '"organization_owner" in roles or "branch_head" not in roles' in decision
    assert "len(branch_locations) != 1" in decision
    assert "FOR UPDATE" in decision
    assert "create_working_copy(" in decision
    assert "None, None, db=db" in decision
    assert "oa.role_id IN ('manager','team_lead')" in decision
    assert "result.rowcount != 1" in decision



def test_copy_access_grants_require_acl_capability_and_revoke_the_grant():
    provider = Path("firebase_authz/supabase_provider.py").read_text(encoding="utf-8")
    grant = provider.split("def set_dataset_grant(", 1)[1].split("\ndef create_working_copy", 1)[0]

    assert 'actor_roles.intersection({"organization_owner", "branch_head"})' in grant
    assert '"dataset.manage_acl" not in set(context.get("permissions", []))' in grant
    assert "if grant_permissions:" in grant
    assert "DELETE FROM resource_grants" in grant
    assert "'operation':" not in grant
    assert '"operation": "grant" if grant_permissions else "revoke"' in grant
