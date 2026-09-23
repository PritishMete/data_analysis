import os
import threading
import pytest

pytestmark = pytest.mark.skipif(not os.environ.get("FIREBASE_DATABASE_EMULATOR_HOST"), reason="Requires the RTDB emulator")

from firebase_authz import service

@pytest.fixture(autouse=True)
def emulator_config(monkeypatch):
    monkeypatch.setenv("FIREBASE_PROJECT_ID", service.PROJECT_ID)
    monkeypatch.setenv("FIREBASE_DATABASE_URL", service.DATABASE_URL)
    monkeypatch.setenv("FIREBASE_DATABASE_EMULATOR_HOST", "127.0.0.1:9000")
    monkeypatch.setenv("INSIGHTFLOW_BOOTSTRAP_SECRET", "test-secret")
    service.firebase_admin.delete_app(service.firebase_admin.get_app()) if service.firebase_admin and service.firebase_admin._apps else None
    service.initialize_firebase()
    service.db.reference("/").delete()
    yield
    service.db.reference("/").delete()

def test_emulator_suspended_missing_and_cross_workspace_access():
    service.db.reference("/").set({
        "users": {"alice": {"suspended": False}, "suspended": {"suspended": True}},
        "workspaces": {
            "a": {
                "members": {"alice": {"roles": {"analyst": True}}},
                "roles": {"analyst": {"permissions": ["data.view"]}},
                "resources": {"r1": {"grants": {"alice": {"permissions": ["data.view"]}}}},
            },
            "b": {"members": {}, "roles": {}, "resources": {}},
        },
    })
    assert service.authorization("alice", "a", "data.view", "r1")["allowed"]
    with pytest.raises(service.PermissionDenied): service.authorization("alice", "b", "data.view", "r1")
    with pytest.raises(service.PermissionDenied): service.authorization("missing", "a", "data.view", "r1")
    with pytest.raises(service.PermissionDenied): service.authorization("suspended", "a", "data.view", "r1")

def test_emulator_action_and_resource_grants_are_both_required():
    service.db.reference("/").set({
        "users": {"alice": {"suspended": False}},
        "workspaces": {
            "a": {
                "members": {"alice": {"roles": {"analyst": True}}},
                "roles": {"analyst": {"permissions": ["data.view"]}},
                "resources": {"r1": {"grants": {"alice": {"permissions": []}}}},
            }
        },
    })
    with pytest.raises(service.PermissionDenied): service.authorization("alice", "a", "data.view", "r1")
    service.db.reference("workspaces/a/resources/r1/grants/alice").set({"permissions": ["data.view"]})
    assert service.authorization("alice", "a", "data.view", "r1")["allowed"]
    service.db.reference("workspaces/a/roles/analyst").set({"permissions": []})
    with pytest.raises(service.PermissionDenied): service.authorization("alice", "a", "data.view", "r1")

def test_emulator_concurrent_first_owner_initialization(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": token, "email_verified": True})
    results = []
    def bootstrap(uid):
        try:
            results.append(service.bootstrap_owner(uid, "test-secret", "workspace", uid))
        except Exception as exc:
            results.append(exc)
    threads = [threading.Thread(target=bootstrap, args=(uid,)) for uid in ("alice", "bob")]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    successes = [item for item in results if isinstance(item, dict)]
    assert len(successes) == 1
    workspace = service.db.reference("workspaces/workspace").get()
    assert workspace["bootstrap"]["owner_uid"] == successes[0]["owner_uid"]
    assert workspace["members"][successes[0]["owner_uid"]]["roles"]["owner"] is True

def test_emulator_partial_bootstrap_recovers_for_same_owner(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": token, "email_verified": True})
    service.db.reference("workspaces/workspace").set({
        "bootstrap": {"initialized": True, "owner_uid": "alice"}
    })
    result = service.bootstrap_owner("alice", "test-secret", "workspace", "alice")
    assert result["owner_uid"] == "alice"
    workspace = service.db.reference("workspaces/workspace").get()
    assert workspace["members"]["alice"]["roles"]["owner"] is True
    assert "owner" in workspace["roles"]

def test_emulator_last_active_owner_is_protected():
    service.db.reference("workspaces/workspace").set({
        "members": {"alice": {"roles": {"owner": True}}}
    })
    service.db.reference("users/alice").set({"suspended": False})
    with pytest.raises(service.PermissionDenied):
        service.last_owner_guard("workspace", "alice")


def test_emulator_resource_scoped_actions_reject_missing_resource_id():
    service.db.reference("/").set({
        "users": {"alice": {"suspended": False}},
        "workspaces": {
            "a": {
                "members": {"alice": {"roles": {"analyst": True}}},
                "roles": {"analyst": {"permissions": ["pivot.create"]}},
                "resources": {},
            }
        },
    })
    with pytest.raises(service.PermissionDenied):
        service.authorization("alice", "a", "pivot.create")
