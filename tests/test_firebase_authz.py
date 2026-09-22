import threading
import pytest
from firebase_authz import service

def test_actions_and_roles_are_explicit():
    assert "worksheet.modify" in service.ACTIONS
    assert "owner" in service.DEFAULT_ROLES

def test_suspended_user_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: (_ for _ in ()).throw(service.PermissionDenied("User is suspended.")))
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
        "resources": {"r1": {"grants": {"u": {"permissions": ["data.view"]}}}},
    })
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")

def test_revoked_role_permission_takes_effect_immediately(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    workspace = {
        "members": {"u": {"roles": {"analyst": True}}},
        "roles": {"analyst": {"permissions": ["data.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": ["data.view"]}}}},
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    assert service.authorization("u", "w", "data.view", "r1")["allowed"] is True
    workspace["roles"]["analyst"]["permissions"] = []
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")

def test_revoked_resource_grant_takes_effect_immediately(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    workspace = {
        "members": {"u": {"roles": {"analyst": True}}},
        "roles": {"analyst": {"permissions": ["data.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": {"data.view": True}}}}},
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    assert service.authorization("u", "w", "data.view", "r1")["allowed"] is True
    workspace["resources"]["r1"]["grants"]["u"]["permissions"] = []
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")

def test_cross_workspace_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {"members": {}, "roles": {}, "resources": {}})
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "workspace-b", "data.view", "resource-a")

def test_invalid_path_ids_are_rejected(monkeypatch):
    with pytest.raises(ValueError):
        service.authorization("u/../x", "w", "data.view", "r")
    with pytest.raises(ValueError):
        service.authorization("u", "w/../x", "data.view", "r")
    with pytest.raises(ValueError):
        service.authorization("u", "w", "data.view", "../r")

def test_self_promotion_is_rejected(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "u"})
    monkeypatch.setattr(service, "authorization", lambda *args, **kwargs: {"allowed": True})
    with pytest.raises(service.PermissionDenied):
        service.mutate_role("u", "owner", True, "token", "w")

def test_last_owner_is_protected(monkeypatch):
    monkeypatch.setattr(service, "_workspace", lambda wid: {
        "members": {"u": {"roles": {"owner": True}}}
    })
    monkeypatch.setattr(service, "_get", lambda path: {"suspended": False})
    with pytest.raises(service.PermissionDenied):
        service.last_owner_guard("w", "u")

def test_bootstrap_transaction_is_atomic_and_concurrent(monkeypatch):
    class Ref:
        def __init__(self):
            self.value = None
            self.lock = threading.Lock()
        def transaction(self, fn):
            with self.lock:
                self.value = fn(self.value)
                return self.value
    ref = Ref()
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": token})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: ref)
    monkeypatch.setenv("INSIGHTFLOW_BOOTSTRAP_SECRET", "secret")
    results = []
    def run(uid):
        try:
            results.append(service.bootstrap_owner(uid, "secret", "w", uid))
        except Exception as exc:
            results.append(exc)
    threads = [threading.Thread(target=run, args=(uid,)) for uid in ("alice", "bob")]
    for t in threads: t.start()
    for t in threads: t.join()
    successes = [x for x in results if isinstance(x, dict)]
    assert len(successes) == 1
    assert ref.value["bootstrap"]["owner_uid"] == successes[0]["owner_uid"]

def test_wrong_firebase_configuration_fails(monkeypatch):
    monkeypatch.setenv("FIREBASE_PROJECT_ID", "wrong-project")
    monkeypatch.setenv("FIREBASE_DATABASE_URL", service.DATABASE_URL)
    with pytest.raises(RuntimeError):
        service.initialize_firebase()

def test_partial_bootstrap_recovers_only_for_same_owner(monkeypatch):
    class Ref:
        def __init__(self):
            self.value = {
                "bootstrap": {"initialized": True, "owner_uid": "alice"},
                "members": {},
            }
        def transaction(self, fn):
            self.value = fn(self.value)
            return self.value
    ref = Ref()
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "alice"})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: ref)
    monkeypatch.setenv("INSIGHTFLOW_BOOTSTRAP_SECRET", "secret")
    result = service.bootstrap_owner("alice", "secret", "w", "alice")
    assert result["owner_uid"] == "alice"
    assert ref.value["members"]["alice"]["roles"]["owner"] is True
    assert "analyst" in ref.value["roles"]
