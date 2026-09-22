import pytest
from firebase_authz import service

def test_actions_and_roles_are_explicit():
    assert "worksheet.modify" in service.ACTIONS
    assert "owner" in service.DEFAULT_ROLES

def test_suspended_user_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": True})
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r")

def test_unknown_action_denied():
    with pytest.raises(ValueError):
        service.authorization("u", "w", "made.up", "r")

def test_missing_resource_rejected(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {})
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view")

def test_role_only_is_not_enough(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {
        "members": {"u": {"roles": {"analyst": True}}},
        "roles": {"analyst": {"permissions": ["data.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": {}}}}},
    })
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")

def test_resource_only_is_not_enough(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {
        "members": {"u": {"roles": {"viewer": True}}},
        "roles": {"viewer": {"permissions": ["history.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": {"data.view": True}}}}},
    })
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")

def test_cross_workspace_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {"members": {}, "roles": {}, "resources": {}})
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "workspace-b", "data.view", "resource-a")
