import os, pytest

pytest.importorskip("firebase_admin")
from firebase_authz import service

def test_actions_are_explicit():
    assert "worksheet.modify" in service.ACTIONS
    assert "owner" in service.DEFAULT_ROLES

def test_suspended_user_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": True})
    with pytest.raises(service.PermissionDenied): service.authorization("u","w","data.view")

def test_unknown_action_denied():
    with pytest.raises(service.PermissionDenied): service.authorization("u","w","made.up")
