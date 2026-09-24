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

def test_bootstrap_transaction_creates_database_backed_owner_records(monkeypatch):
    class Ref:
        def __init__(self):
            self.value = None
            self.lock = threading.Lock()
        def transaction(self, fn):
            with self.lock:
                self.value = fn(self.value)
                return self.value
    ref = Ref()
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "alice", "email": "alice@example.com", "email_verified": False
    })
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: ref)

    result = service.bootstrap_owner("token", "ABC")

    workspace = ref.value["workspaces"][result["workspace_id"]]
    assert workspace["organization"]["name"] == "ABC"
    assert workspace["members"]["alice"]["roles"]["owner"] is True
    assert workspace["members"]["alice"]["principal_id"] == ref.value["users"]["alice"]["principal_id"]
    assert workspace["roles"]["organization_owner"]["permissions"] == sorted(service.DEFAULT_ROLES["organization_owner"])
    assert result["organization_id"] == result["workspace_id"]


def test_bootstrap_allows_authenticated_user_to_create_another_organization(monkeypatch):
    class Ref:
        def __init__(self):
            self.value = {
                "users": {
                    "alice": {
                        "status": "active",
                        "email": "alice@example.com",
                        "employee_id": "EMP001",
                        "principal_id": "EMP001",
                    }
                },
                "workspaces": {
                    "org_existing": {
                        "organization": {"organization_id": "org_existing", "name": "Existing"},
                        "members": {
                            "alice": {
                                "status": "active",
                                "employee_id": "EMP001",
                                "principal_id": "EMP001",
                                "roles": {"owner": True},
                            }
                        },
                    }
                },
            }
        def transaction(self, fn):
            self.value = fn(self.value)
            return self.value

    ref = Ref()
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "alice", "email": "alice@example.com", "email_verified": False
    })
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: ref)

    result = service.bootstrap_owner("token", "Second Organization")

    assert result["workspace_id"] != "org_existing"
    assert ref.value["workspaces"][result["workspace_id"]]["members"]["alice"]["principal_id"] == "EMP001"
    assert ref.value["users"]["alice"]["principal_id"] == "EMP001"


def test_wrong_firebase_configuration_fails(monkeypatch):
    monkeypatch.setenv("FIREBASE_PROJECT_ID", "wrong-project")
    monkeypatch.setenv("FIREBASE_DATABASE_URL", service.DATABASE_URL)
    with pytest.raises(RuntimeError):
        service.initialize_firebase()

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


def test_new_user_without_invitation_is_bootstrap_candidate(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {})
    monkeypatch.setattr(service, "_identity_candidates", lambda email, provider, provider_subject: [])
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [])
    monkeypatch.setattr(service, "pending_invitations_for_email", lambda email: [])
    monkeypatch.setattr(service, "_identity_candidates", lambda email, provider, subject: [])
    context = service.authentication_context("new-user", "workspace", email_verified=True, email="new@example.com")
    assert context["authorization_state"] == "new_company_candidate"
    assert context["has_authorization_record"] is False
    assert context["workspace_authorized"] is False

def test_new_user_with_invitation_is_not_a_bootstrap_candidate(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {})
    monkeypatch.setattr(service, "_identity_candidates", lambda email, provider, provider_subject: [])
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [])
    monkeypatch.setattr(service, "_identity_candidates", lambda email, provider, subject: [])
    monkeypatch.setattr(service, "pending_invitations_for_email", lambda email: [{
        "invitation_id": "inv1",
        "workspace_id": "org1",
        "organization_id": "org1",
        "organization_name": "Acme",
        "role_id": "employee",
    }])
    context = service.authentication_context("new-user", email_verified=True, email="new@example.com")
    assert context["authorization_state"] == "pending_invitation"
    assert context["pending_invitations"][0]["role_id"] == "employee"


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
        "principal_id": "emp_123",
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
        def get(self): return {}
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
    monkeypatch.setattr(service, "_raw_user", lambda uid: {})
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
    monkeypatch.setattr(service, "_get", lambda path: {"suspended": False} if path.startswith("users/") else None)
    monkeypatch.setattr(service.auth, "revoke_refresh_tokens", lambda uid: None)
    class Ref:
        def set(self, value):
            return None
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())
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
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "lead", "email_verified": True, "auth_time": 9999999999,
    })
    monkeypatch.setattr(service, "require_recent_auth", lambda claims: claims)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    captured = {}
    class Ref:
        def set(self, value): captured["value"] = value
        def get(self): return {}
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
    monkeypatch.setattr(service, "_user", lambda uid: {"status": "active"})
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "lead", "email_verified": True, "auth_time": 9999999999,
    })
    monkeypatch.setattr(service, "require_recent_auth", lambda claims: claims)
    with pytest.raises(service.PermissionDenied):
        service.set_dataset_grant(
            "org", "ds1", "employee",
            ["dataset.view_original"], "token",
        )


def test_unknown_verified_identity_is_not_a_technical_missing_record(monkeypatch):
    monkeypatch.setattr(service, "_get", lambda path: {} if path in {"users", "workspaces"} else {})
    context = service.authentication_context(
        "fresh",
        email_verified=True,
        email="fresh@example.com",
        provider="google.com",
        provider_subject="google-fresh",
    )
    assert context["authorization_state"] == "new_company_candidate"
    assert context["has_authorization_record"] is False


def test_verified_recreated_identity_relinks_to_stable_employee(monkeypatch):
    root_users = {
        "uid_a": {
            "status": "active",
            "email": "employee@example.com",
            "employee_id": "EMP001",
            "principal_id": "EMP001",
        }
    }
    root_workspaces = {
        "org_1": {
            "organization": {"organization_id": "org_1", "name": "Acme"},
            "members": {
                "uid_a": {
                    "employee_id": "EMP001",
                    "principal_id": "EMP001",
                    "status": "active",
                    "roles": {"employee": True},
                    "identity_bindings": {"google.com": ["google-123"]},
                }
            },
        }
    }
    writes = {}
    class Ref:
        def __init__(self, path):
            self.path = path
        def update(self, value):
            writes[self.path] = value
        def set(self, value):
            writes[self.path] = value
    def fake_get(path):
        if path == "users": return root_users
        if path == "workspaces": return root_workspaces
        if path == "workspaces/org_1/members/uid_a":
            return root_workspaces["org_1"]["members"]["uid_a"]
        return {}
    monkeypatch.setattr(service, "_get", fake_get)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service, "audit_event", lambda *args, **kwargs: None)
    monkeypatch.setattr(service.db, "reference", lambda path: Ref(path))
    result = service.resolve_principal(
        "uid_b",
        "employee@example.com",
        "google.com",
        "google-123",
        True,
    )
    assert result["state"] == "relinked"
    assert result["principal_id"] == "EMP001"
    assert result["member_uid"] == "uid_a"
    assert writes["users/uid_b"]["linked_member_uid"] == "uid_a"
    assert writes["users/uid_b"]["principal_id"] == "EMP001"



def test_verified_email_alone_cannot_relink_recreated_identity(monkeypatch):
    users = {
        "uid_a": {
            "status": "active",
            "email": "employee@example.com",
            "employee_id": "EMP001",
        }
    }
    workspaces = {
        "org_1": {
            "members": {
                "uid_a": {
                    "employee_id": "EMP001",
                    "status": "active",
                    "roles": {"employee": True},
                    "identity_bindings": {"google.com": ["different-provider-subject"]},
                }
            }
        }
    }
    monkeypatch.setattr(
        service,
        "_get",
        lambda path: users if path == "users" else workspaces if path == "workspaces" else {},
    )
    result = service.resolve_principal(
        "uid_b",
        "employee@example.com",
        "google.com",
        "new-provider-subject",
        True,
    )
    assert result["state"] == "new_company_candidate"

def test_suspended_employee_cannot_relink_recreated_identity(monkeypatch):
    root_users = {
        "uid_a": {
            "status": "suspended",
            "email": "employee@example.com",
            "employee_id": "EMP001",
        }
    }
    root_workspaces = {
        "org_1": {
            "members": {
                "uid_a": {
                    "employee_id": "EMP001",
                    "status": "suspended",
                    "roles": {"employee": True},
                }
            }
        }
    }
    monkeypatch.setattr(
        service,
        "_get",
        lambda path: root_users if path == "users" else root_workspaces if path == "workspaces" else (
            root_workspaces["org_1"]["members"]["uid_a"]
            if path == "workspaces/org_1/members/uid_a"
            else {}
        ),
    )
    result = service.resolve_principal(
        "uid_b",
        "employee@example.com",
        "google.com",
        "google-123",
        True,
    )
    assert result["state"] == "suspended"


def test_removed_identity_can_bootstrap_from_a_valid_firebase_token(monkeypatch):
    monkeypatch.setattr(service, "verify_id_token", lambda token: {
        "uid": "new_uid",
        "email": "employee@example.com",
        "email_verified": False,
    })
    root = {
        "users": {
            "old_uid": {
                "status": "active",
                "email": "employee@example.com",
                "employee_id": "EMP001",
            }
        },
        "workspaces": {},
    }
    class Ref:
        def transaction(self, fn):
            return fn(root)
    monkeypatch.setattr(service, "initialize_firebase", lambda: None)
    monkeypatch.setattr(service.db, "reference", lambda path: Ref())

    result = service.bootstrap_owner("token", "Not Allowed")

    assert result["workspace_id"] in root["workspaces"]
    assert root["workspaces"][result["workspace_id"]]["organization"]["name"] == "Not Allowed"



def test_ambiguous_verified_email_fails_closed(monkeypatch):
    users = {
        "uid_a": {"status": "active", "email": "same@example.com", "employee_id": "EMP001"},
        "uid_b": {"status": "active", "email": "same@example.com", "employee_id": "EMP002"},
    }
    workspaces = {
        "org_a": {"members": {"uid_a": {"employee_id": "EMP001", "status": "active"}}},
        "org_b": {"members": {"uid_b": {"employee_id": "EMP002", "status": "active"}}},
    }
    monkeypatch.setattr(service, "_get", lambda path: users if path == "users" else workspaces if path == "workspaces" else {})
    result = service.resolve_principal(
        "uid_c",
        "same@example.com",
        "google.com",
        "google-c",
        True,
    )
    assert result["state"] == "ambiguous_identity"


def test_unverified_identity_cannot_link_existing_employee(monkeypatch):
    monkeypatch.setattr(service, "_get", lambda path: {
        "users": {"uid_a": {"status": "active", "email": "employee@example.com", "employee_id": "EMP001"}},
        "workspaces": {"org": {"members": {"uid_a": {"employee_id": "EMP001", "status": "active"}}}},
    }.get(path, {}))
    result = service.resolve_principal(
        "uid_b",
        "employee@example.com",
        "google.com",
        "google-b",
        False,
    )
    assert result["state"] == "new_company_candidate"


def test_relinked_identity_keeps_existing_resource_acl(monkeypatch):
    workspace = {
        "members": {
            "uid_a": {
                "employee_id": "EMP001",
                "principal_id": "EMP001",
                "status": "active",
                "roles": {"employee": True},
            }
        },
        "roles": {
            "employee": {"permissions": sorted(service.DEFAULT_ROLES["employee"])},
        },
        "resources": {
            "ds_1": {
                "grants": {
                    "uid_a": {"permissions": ["data.view"]},
                }
            }
        },
    }
    monkeypatch.setattr(service, "_user", lambda uid: {
        "status": "active",
        "principal_id": "EMP001",
        "employee_id": "EMP001",
        "linked_member_uid": "uid_a",
    })
    monkeypatch.setattr(service, "_workspace", lambda wid: workspace)
    decision = service.authorization("uid_b", "org_1", "data.view", "ds_1")
    assert decision["allowed"] is True
    assert decision["principal_id"] == "EMP001"

def test_existing_authz_record_without_membership_is_no_organization_access(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {
        "status": "active",
        "email": "employee@example.com",
        "employee_id": "EMP001",
        "principal_id": "EMP001",
    })
    monkeypatch.setattr(service, "workspace_memberships", lambda uid, include_user=False: [])
    monkeypatch.setattr(service, "pending_invitations_for_email", lambda email: [])
    context = service.authentication_context(
        "uid-a",
        email_verified=True,
        email="employee@example.com",
    )
    assert context["authorization_state"] == "no_organization_access"
    assert context["has_authorization_record"] is True
    assert context["workspace_authorized"] is False


def test_removed_authz_record_is_terminal_removed_state(monkeypatch):
    monkeypatch.setattr(service, "_raw_user", lambda uid: {
        "status": "removed",
        "email": "employee@example.com",
        "employee_id": "EMP001",
        "principal_id": "EMP001",
    })
    context = service.authentication_context(
        "uid-a",
        email_verified=True,
        email="employee@example.com",
    )
    assert context["authorization_state"] == "removed"
    assert context["account_status"] == "removed"
    assert context["workspace_authorized"] is False


def test_backend_lookup_failure_is_not_classified_as_new_company(monkeypatch):
    def fail(_uid):
        raise RuntimeError("Realtime Database unavailable")
    monkeypatch.setattr(service, "_raw_user", fail)
    with pytest.raises(RuntimeError, match="Realtime Database unavailable"):
        service.authentication_context(
            "uid-a",
            email_verified=True,
            email="employee@example.com",
        )
