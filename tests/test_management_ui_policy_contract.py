from firebase_authz.management_domain import _management_ui_policy


def test_organization_owner_policy_is_organization_scoped_and_read_only_for_branch_data():
    policy = _management_ui_policy("organization_owner")

    assert policy["management_tier"] == "organization"
    assert "organization" in policy["sections"]
    assert "dataAccess" in policy["sections"]
    assert "audit" in policy["sections"]
    assert "dataset.view_original" in policy["capabilities"]
    assert "dataset.upload" not in policy["capabilities"]
    assert "dataset.copy.request" in policy["capabilities"]
    assert "dataset.authorize_copy" not in policy["capabilities"]
    assert "dataset.delete" not in policy["capabilities"]


def test_branch_head_policy_retains_branch_dataset_management_capabilities():
    policy = _management_ui_policy("branch_head")

    assert policy["management_tier"] == "branch"
    assert "dataAccess" in policy["sections"]
    assert "dataset.upload" in policy["capabilities"]
    assert "dataset.proposal.submit" in policy["capabilities"]
    assert "dataset.upload.direct" in policy["capabilities"]
    assert "dataset.view_original" in policy["capabilities"]
    assert "dataset.delete" in policy["capabilities"]
    assert "dataset.proposal.review" in policy["capabilities"]
    assert "dataset.authorize_copy" in policy["capabilities"]


def test_manager_policy_exposes_team_and_proposal_workspace_without_default_upload_grant():
    policy = _management_ui_policy("manager")

    assert policy["management_tier"] == "team"
    assert "people" in policy["sections"]
    assert "dataAccess" in policy["sections"]
    assert "dataset.upload" in policy["capabilities"]


def test_team_lead_policy_is_section_scoped_without_branch_administration():
    policy = _management_ui_policy("team_lead")

    assert policy["management_tier"] == "section"
    assert "people" in policy["sections"]
    assert "dataAccess" in policy["sections"]
    assert "organization" not in policy["sections"]
    assert "invitations" not in policy["sections"]
    assert "audit" not in policy["sections"]
    assert "dataset.upload" not in policy["capabilities"]


def test_professional_designation_does_not_create_management_capabilities():
    policy = _management_ui_policy("data_analyst")

    assert policy["management_tier"] == "member"
    assert policy["sections"] == ["overview"]
    assert policy["capabilities"] == []
    assert "read_only" not in policy


def test_external_viewer_policy_is_member_scoped_and_read_only():
    policy = _management_ui_policy("external_viewer")

    assert policy["management_tier"] == "member"
    assert policy["sections"] == ["overview", "dataAccess"]
    assert policy["capabilities"] == []
    assert policy["read_only"] is True
