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
    if service.firebase_admin and service.firebase_admin._apps:
        service.firebase_admin.delete_app(service.firebase_admin.get_app())
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

def test_emulator_concurrent_same_user_bootstrap_is_single_owner(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "alice", "email": "alice@example.com", "email_verified": True
    })
    results = []
    def bootstrap():
        try:
            results.append(service.bootstrap_owner("token", "Acme"))
        except Exception as exc:
            results.append(exc)
    threads = [threading.Thread(target=bootstrap) for _ in range(2)]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    successes = [item for item in results if isinstance(item, dict)]
    assert len(successes) == 1
    workspace_id = successes[0]["workspace_id"]
    workspace = service.db.reference("workspaces/" + workspace_id).get()
    assert workspace["members"]["alice"]["roles"]["owner"] is True
    assert service.db.reference("users/alice").get()["bootstrap_organization_id"] == workspace_id

def test_emulator_bootstrap_creates_default_roles_and_active_membership(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "owner", "email": "owner@example.com", "email_verified": True
    })
    result = service.bootstrap_owner("token", "Acme")
    workspace = service.db.reference("workspaces/" + result["workspace_id"]).get()
    assert workspace["organization"]["name"] == "Acme"
    assert workspace["members"]["owner"]["status"] == "active"
    assert workspace["members"]["owner"]["roles"]["owner"] is True
    assert set(service.DEFAULT_ROLES).issubset(workspace["roles"])

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


def test_emulator_fresh_user_is_onboarding_candidate(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "fresh", "email": "fresh@example.com", "email_verified": True
    })
    context = service.authentication_context("fresh", email_verified=True, email="fresh@example.com")
    assert context["authorization_state"] == "bootstrap_candidate"
    assert context["has_authorization_record"] is False

def test_emulator_invited_user_cannot_bootstrap(monkeypatch):
    service.db.reference("workspaces/existing").set({
        "organization": {"organization_id": "existing", "name": "Acme"},
        "invitations": {"inv1": {
            "status": "invited",
            "email": "employee@example.com",
            "role_id": "employee",
        }},
        "members": {}, "roles": {}, "resources": {},
    })
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "employee", "email": "employee@example.com", "email_verified": True
    })
    context = service.authentication_context("employee", email_verified=True, email="employee@example.com")
    assert context["authorization_state"] == "pending_invitation"
    with pytest.raises(service.BootstrapDenied):
        service.bootstrap_owner("token", "Should Not Create")


def test_emulator_suspended_invited_user_cannot_accept_invitation(monkeypatch):
    service.db.reference("users/suspended").set({
        "status": "suspended",
        "email": "employee@example.com",
    })
    service.db.reference("workspaces/existing").set({
        "organization": {"organization_id": "existing", "name": "Acme"},
        "invitations": {"inv1": {
            "status": "invited",
            "email": "employee@example.com",
            "role_id": "employee",
        }},
        "members": {}, "roles": {}, "resources": {},
    })
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "suspended", "email": "employee@example.com", "email_verified": True
    })
    with pytest.raises(service.PermissionDenied):
        service.accept_invitation("existing", "inv1", "token")
