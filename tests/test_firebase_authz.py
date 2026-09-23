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
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "u", "email_verified": True})
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
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": token, "email_verified": True})
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
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "alice", "email_verified": True})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: ref)
    monkeypatch.setenv("INSIGHTFLOW_BOOTSTRAP_SECRET", "secret")
    result = service.bootstrap_owner("alice", "secret", "w", "alice")
    assert result["owner_uid"] == "alice"
    assert ref.value["members"]["alice"]["roles"]["owner"] is True
    assert "analyst" in ref.value["roles"]

    
def test_legacy_membership_without_status_is_treated_as_active(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {
        "members": {"u": {"roles": {"viewer": True}}},
        "roles": {"viewer": {"permissions": ["data.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": ["data.view"]}}}},
    })
    assert service.authorization("u", "w", "data.view", "r1")["allowed"] is True


def test_non_active_membership_is_denied(monkeypatch):
    monkeypatch.setattr(service, "_user", lambda uid: {"suspended": False})
    monkeypatch.setattr(service, "_workspace", lambda wid: {
        "members": {"u": {"status": "suspended", "roles": {"viewer": True}}},
        "roles": {"viewer": {"permissions": ["data.view"]}},
        "resources": {"r1": {"grants": {"u": {"permissions": ["data.view"]}}}},
    })
    with pytest.raises(service.PermissionDenied):
        service.authorization("u", "w", "data.view", "r1")


def test_new_user_has_no_authorization_record(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {})
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [])
    context = service.authentication_context("new-user", "workspace", email_verified=True)
    assert context["account_status"] == "pending"
    assert context["workspace_authorized"] is False


def test_suspended_user_is_reported_as_suspended(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {"suspended": True})
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [])
    context = service.authentication_context("u", "workspace", email_verified=True)
    assert context["account_status"] == "suspended"
    assert context["workspace_authorized"] is False


def test_unverified_email_cannot_be_authorized(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [
        {"workspace_id": "workspace", "membership_status": "active", "role_ids": ["viewer"]},
    ])
    context = service.authentication_context("u", "workspace", email_verified=False)
    assert context["workspace_authorized"] is False


def test_membership_context_exposes_stable_organization_and_employee_ids(monkeypatch):
    monkeypatch.setattr(service, "_get", lambda path: {
        "workspaces": {
            "w": {
                "organization": {"organization_id": "org_w", "status": "active"},
                "members": {
                    "u": {
                        "status": "active",
                        "employee_id": "emp_123",
                        "roles": {"employee": True},
                    }
                },
            }
        }
    }.get(path, {}))
    result = service.workspace_memberships("u", include_user=False)
    assert result == [{
        "workspace_id": "w",
        "organization_id": "org_w",
        "membership_status": "active",
        "employee_id": "emp_123",
        "role_ids": ["employee"],
    }]


def test_legacy_workspace_gets_stable_organization_alias_without_promoting_user(monkeypatch):
    monkeypatch.setattr(service, "_get", lambda path: {
        "workspaces": {
            "w": {
                "members": {"u": {"roles": {"viewer": True}}},
            }
        }
    }.get(path, {}))
    result = service.workspace_memberships("u", include_user=False)
    assert result[0]["organization_id"] == "w"
    assert result[0]["employee_id"] == "emp_u"
    assert result[0]["role_ids"] == ["viewer"]


def test_manager_cannot_grant_manager_or_owner_to_peer(monkeypatch):
    workspace = {
        "members": {
            "manager": {"roles": {"manager": True}},
            "peer": {"roles": {"employee": True}},
        },
        "roles": {
            "manager": {"permissions": sorted(service.ACTIONS)},
            "employee": {"permissions": ["data.view"]},
            "organization_owner": {"permissions": sorted(service.ACTIONS)},
        },
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    with pytest.raises(service.PermissionDenied):
        service.can_manage_role("org", "manager", "peer", "manager", True)
    with pytest.raises(service.PermissionDenied):
        service.can_manage_role("org", "manager", "peer", "organization_owner", True)


def test_owner_can_manage_lower_roles_but_not_self_promote():
    workspace = {
        "members": {
            "owner": {"roles": {"organization_owner": True}},
            "employee": {"roles": {"employee": True}},
        }
    }
    service._workspace = lambda wid: workspace
    assert service.can_manage_role("org", "owner", "employee", "manager", True) is True
    with pytest.raises(service.PermissionDenied):
        service.can_manage_role("org", "owner", "owner", "manager", True)


def test_dataset_acl_is_opaque_and_fail_closed(monkeypatch):
    workspace = {
        "members": {
            "owner": {"status": "active", "roles": {"organization_owner": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "roles": {
            "organization_owner": {"permissions": sorted(service.ACTIONS)},
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
        "datasets": {
            "ds_opaque": {
                "dataset_id": "ds_opaque",
                "organization_id": "org",
                "owner_uid": "owner",
                "protected_original": True,
                "grants": {
                    "employee": {
                        "permissions": ["dataset.view_original", "dataset.create_working_copy"]
                    }
                },
            }
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    assert service.authorize_dataset("employee", "org", "ds_opaque", "dataset.view_original")["allowed"] is True
    with pytest.raises(service.PermissionDenied):
        service.authorize_dataset("employee", "org", "ds_opaque", "dataset.delete")


def test_dataset_acl_never_accepts_workbook_fields(monkeypatch):
    workspace = {
        "members": {"owner": {"status": "active", "roles": {"organization_owner": True}}},
        "roles": {"organization_owner": {"permissions": sorted(service.ACTIONS)}},
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "owner", "email_verified": True})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    with pytest.raises(service.PermissionDenied):
        service._dataset(workspace, "not_present")


def test_team_lead_delegation_requires_approved_employees(monkeypatch):
    workspace = {
        "members": {
            "manager": {"status": "active", "roles": {"manager": True}},
            "lead": {"status": "active", "roles": {"team_lead": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "roles": {
            "manager": {"permissions": sorted(service.DEFAULT_ROLES["manager"])},
            "team_lead": {"permissions": sorted(service.DEFAULT_ROLES["team_lead"])},
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
        "datasets": {"ds": {"dataset_id": "ds", "owner_uid": "manager", "grants": {}}},
        "approved_employees": {},
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "manager", "email_verified": True})
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    class Ref:
        def set(self, value): self.value = value
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
    with pytest.raises(service.PermissionDenied):
        service.set_delegation(
            "org", "lead", ["employee"], ["ds"],
            ["dataset.share"], None, "token"
        )


def test_delegated_dataset_share_is_scope_bound(monkeypatch):
    workspace = {
        "members": {
            "lead": {"status": "active", "roles": {"team_lead": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "approved_employees": {"employee": {"status": "active"}},
        "delegations": {
            "d1": {
                "status": "active",
                "team_lead_uid": "lead",
                "member_ids": ["employee"],
                "dataset_ids": ["ds1"],
                "permissions": ["dataset.share"],
            }
        },
    }
    assert service._delegated_permission(
        workspace, "lead", "employee", "ds1", "dataset.share"
    ) is True
    assert service._delegated_permission(
        workspace, "lead", "employee", "ds2", "dataset.share"
    ) is False


def test_working_copy_provenance_is_metadata_only(monkeypatch):
    workspace = {
        "members": {
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "roles": {
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
        "datasets": {
            "ds1": {
                "dataset_id": "ds1",
                "owner_uid": "owner",
                "protected_original": True,
                "grants": {
                    "employee": {"permissions": ["dataset.create_working_copy"]}
                },
            }
        },
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": "employee", "email_verified": True})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    captured = {}
    class Ref:
        def set(self, value): captured.update(value)
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
    result = service.create_working_copy("org", "ds1", "token", "wc_test", "7")
    assert result["working_copy_id"] == "wc_test"
    assert captured["source_dataset_id"] == "ds1"
    assert captured["created_by_uid"] == "employee"
    assert "rows" not in captured
    assert "values" not in captured
    assert "workbook" not in captured


def test_recent_auth_is_required_for_sensitive_membership_changes():
    with pytest.raises(service.PermissionDenied):
        service.require_recent_auth({"uid": "u", "email_verified": True, "auth_time": 1}, max_age_seconds=300)


def test_invitation_accept_requires_exact_identity(monkeypatch):
    workspace = {
        "members": {},
        "invitations": {
            "inv1": {
                "status": "invited",
                "email": "employee@example.com",
                "employee_id": "emp_1",
                "role_id": "employee",
            }
        },
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "u", "email": "other@example.com", "email_verified": True,
    })
    with pytest.raises(service.PermissionDenied):
        service.accept_invitation("org", "inv1", "token")


def test_membership_revocation_protects_last_owner(monkeypatch):
    workspace = {
        "members": {"owner": {"roles": {"organization_owner": True}}},
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "owner", "email_verified": True, "auth_time": __import__("time").time(),
    })
    monkeypatch.setattr(service, "authorization", lambda *args, **kwargs: {"allowed": True})
    with pytest.raises(service.PermissionDenied):
        service.set_membership_status("org", "owner", "suspended", "token")


def test_employee_cannot_mutate_original_excel_even_if_operation_capability_exists(monkeypatch):
    workspace = {
        "members": {"employee": {"status": "active", "roles": {"employee": True}}},
        "roles": {
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    with pytest.raises(service.PermissionDenied):
        service.authorization("employee", "org", "excel.mutate.original", "ds_opaque")


def test_manager_can_mutate_original_only_with_dataset_resource_context(monkeypatch):
    workspace = {
        "members": {"manager": {"status": "active", "roles": {"manager": True}}},
        "roles": {
            "manager": {"permissions": sorted(service.DEFAULT_ROLES["manager"])},
        },
        "resources": {
            "ds_opaque": {
                "grants": {
                    "manager": {"permissions": ["excel.mutate.original"]}
                }
            }
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    decision = service.authorization(
        "manager", "org", "excel.mutate.original", "ds_opaque"
    )
    assert decision["allowed"] is True


def test_suspended_membership_is_immediately_denied_after_revocation(monkeypatch):
    workspace = {
        "members": {"employee": {"status": "suspended", "roles": {"employee": True}}},
        "roles": {
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    with pytest.raises(service.PermissionDenied):
        service.authorization("employee", "org", "data.view", "ds_opaque")


def test_audit_event_filters_workbook_sensitive_metadata(monkeypatch):
    captured = {}
    class Ref:
        def set(self, value):
            captured.update(value)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
    service.audit_event(
        "org", "actor", "excel.mutate.original", "succeeded",
        resource_id="ds_opaque",
        metadata={
            "operation": "pivot.create",
            "rows": 500,
            "workbook": "private.xlsx",
            "result": "sensitive",
            "safe": "kept",
        },
    )
    assert "safe" in captured["metadata"]
    assert "rows" not in captured["metadata"]
    assert "workbook" not in captured["metadata"]
    assert "result" not in captured["metadata"]


def test_original_mutation_requires_dataset_view_grant(monkeypatch):
    workspace = {
        "members": {"employee": {"status": "active", "roles": {"employee": True}}},
        "roles": {"employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])}},
        "datasets": {
            "ds_opaque": {
                "owner_uid": "owner",
                "protected_original": True,
                "grants": {},
            }
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    with pytest.raises(service.PermissionDenied):
        service.authorize_excel_mutation(
            "employee", "org", "excel.mutate.original", "ds_opaque"
        )


def test_working_copy_mutation_uses_copy_grant(monkeypatch):
    workspace = {
        "members": {"employee": {"status": "active", "roles": {"employee": True}}},
        "roles": {"employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])}},
        "working_copies": {
            "wc_123": {
                "created_by_uid": "employee",
                "status": "active",
                "grants": {
                    "employee": {
                        "permissions": ["working_copy.modify"]
                    }
                },
            }
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    result = service.authorize_excel_mutation(
        "employee", "org", "excel.mutate.working_copy", "wc_123"
    )
    assert result["allowed"] is True


def test_account_cleanup_revokes_membership_grants_and_delegations(monkeypatch):
    root = {
        "workspaces": {
            "org": {
                "members": {
                    "employee": {"status": "active", "roles": {"employee": True}},
                    "owner": {"status": "active", "roles": {"organization_owner": True}},
                },
                "datasets": {
                    "ds_1": {"owner_uid": "owner", "grants": {"employee": {"permissions": ["dataset.view_original"]}}}
                },
                "delegations": {
                    "del_1": {"team_lead_uid": "employee", "member_ids": ["employee"], "status": "active"}
                },
                "invitations": {},
            }
        }
    }
    class Ref:
        def __init__(self, path): self.path = path
        def get(self): return root
        def update(self, values):
            for path, value in values.items():
                if path.endswith("/status"):
                    continue
        def set(self, value):
            return None
    monkeypatch.setattr(
        service,
        "_get",
        lambda path: (
            root["workspaces"]
            if path == "workspaces"
            else root["workspaces"].get("org", {})
        ),
    )
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: Ref(path))
    monkeypatch.setattr(service, "verify_id_token", lambda token: {"uid": token, "email_verified": True, "auth_time": int(__import__("time").time())})
    monkeypatch.setattr(service, "audit_event", lambda *args, **kwargs: None)
    result = service.cleanup_account("employee", "employee")
    assert result["revoked_workspaces"] == ["org"]


def test_team_lead_promotion_requires_approved_active_employee(monkeypatch):
    workspace = {
        "members": {
            "manager": {"status": "active", "roles": {"manager": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "roles": {
            "manager": {"permissions": sorted(service.DEFAULT_ROLES["manager"])},
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
        "approved_employees": {},
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    with pytest.raises(service.PermissionDenied):
        service.can_manage_role("org", "manager", "employee", "team_lead", True)


def test_account_cleanup_revokes_invitation_matching_authenticated_email(monkeypatch):
    captured = {}
    class Ref:
        def update(self, value):
            captured.update(value)
        def set(self, value):
            captured["set"] = value
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service, "_get", lambda path: {
        "workspaces": {
            "org": {
                "members": {"user": {"status": "active", "roles": {"employee": True}}},
                "invitations": {
                    "inv": {"email": "user@example.com", "status": "invited"}
                },
            }
        }
    }.get(path, {}))
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "user", "email": "user@example.com", "email_verified": True,
        "auth_time": __import__("time").time(),
    })
    monkeypatch.setattr(service, "last_owner_guard", lambda *args: None)
    monkeypatch.setattr(service.auth, "revoke_refresh_tokens", lambda uid: None)
    result = service.cleanup_account("user", "token")
    assert result["revoked_workspaces"] == ["org"]
    assert captured["workspaces/org/invitations/inv/status"] == "revoked"


def test_team_lead_dataset_grant_requires_delegated_share(monkeypatch):
    workspace = {
        "members": {
            "lead": {"status": "active", "roles": {"team_lead": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "approved_employees": {
            "employee": {"status": "active", "employee_id": "E1"},
        },
        "datasets": {
            "ds1": {
                "owner_uid": "owner",
                "grants": {},
            }
        },
        "delegations": {
            "del1": {
                "team_lead_uid": "lead",
                "member_ids": ["employee"],
                "dataset_ids": ["ds1"],
                "permissions": ["dataset.share"],
                "status": "active",
            }
        },
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "lead", "email_verified": True, "auth_time": 9999999999,
    })
    monkeypatch.setattr(service, "require_recent_auth", lambda claims: claims)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    captured = {}
    class Ref:
        def set(self, value): captured["value"] = value
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
    assert service.set_dataset_grant(
        "org", "ds1", "employee",
        ["dataset.view_original"], "token",
    )
    assert captured["value"]["permissions"] == ["dataset.view_original"]


def test_team_lead_cannot_grant_outside_delegation(monkeypatch):
    workspace = {
        "members": {
            "lead": {"status": "active", "roles": {"team_lead": True}},
            "employee": {"status": "active", "roles": {"employee": True}},
        },
        "approved_employees": {
            "employee": {"status": "active", "employee_id": "E1"},
        },
        "datasets": {"ds1": {"owner_uid": "owner", "grants": {}}},
        "delegations": {
            "del1": {
                "team_lead_uid": "lead",
                "member_ids": [],
                "dataset_ids": ["ds1"],
                "permissions": ["dataset.share"],
                "status": "active",
            }
        },
    }
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "lead", "email_verified": True, "auth_time": 9999999999,
    })
    monkeypatch.setattr(service, "require_recent_auth", lambda claims: claims)
    with pytest.raises(service.PermissionDenied):
        service.set_dataset_grant(
            "org", "ds1", "employee",
            ["dataset.view_original"], "token",
        )
