import pytest

from dataset_storage import service


def test_managed_dataset_authorization_always_resolves_resource_context(monkeypatch):
    calls = []

    monkeypatch.setattr(
        service,
        "_authorization_context",
        lambda claims, workspace_id: {
            "workspace_authorized": True,
            "permissions": ["dataset.manage_acl", "dataset.view_original"],
        },
    )

    def fake_authorize_dataset(claims, workspace_id, dataset_id, action):
        calls.append((workspace_id, dataset_id, action))
        return {
            "authorized": True,
            "workspace_id": workspace_id,
            "resource_id": dataset_id,
            "action": action,
        }

    def forbidden_workspace_only_authorize(*args, **kwargs):
        raise AssertionError("managed dataset authorization must not bypass the resource context")

    monkeypatch.setattr(service, "authorize_dataset", fake_authorize_dataset)
    monkeypatch.setattr(service, "authorize", forbidden_workspace_only_authorize)

    result = service._authorize_dataset(
        {"uid": "owner"},
        "workspace-owner",
        "dataset-owner",
        "dataset.view_original",
    )

    assert result["authorized"] is True
    assert result["resource_id"] == "dataset-owner"
    assert calls == [
        ("workspace-owner", "dataset-owner", "dataset.view_original")
    ]


def test_managed_dataset_resource_authorization_does_not_grant_without_context(monkeypatch):
    def missing_context(*args, **kwargs):
        raise service.PermissionDenied("Resource authorization context required.")

    monkeypatch.setattr(service, "_authorization_context", missing_context)

    with pytest.raises(service.PermissionDenied, match="Resource authorization context required"):
        service._authorize_dataset(
            {"uid": "owner"},
            "workspace-owner",
            "dataset-owner",
            "dataset.view_original",
        )
