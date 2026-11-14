import inspect

from firebase_authz.management_domain import (
    _management_ui_policy,
    update_location,
)
from firebase_authz.management_routes import LocationUpdateRequest


def test_location_edit_request_only_accepts_the_ordinary_name_field():
    assert set(LocationUpdateRequest.model_fields) == {"name"}


def test_location_update_uses_assigned_scope_and_preserves_primary_identity():
    source = inspect.getsource(update_location)

    assert "_require_location_manage(db, actor, location_id)" in source
    assert "UPDATE locations" in source
    assert "SET name=:name, updated_at=now()" in source
    assert "location_id=:location" in source
    assert "SET location_id" not in source
    assert "branch_identifier=" not in source


def test_only_owner_and_branch_head_receive_location_update_ui_capability():
    assert "location.update" in _management_ui_policy("organization_owner")["capabilities"]
    assert "location.update" in _management_ui_policy("branch_head")["capabilities"]
    assert "location.update" not in _management_ui_policy("manager")["capabilities"]
    assert "location.update" not in _management_ui_policy("team_lead")["capabilities"]
