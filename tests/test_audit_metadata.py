import json
import logging
from contextlib import contextmanager

from dataset_storage import service as dataset_service
from firebase_authz import supabase_provider


class _Result:
    def __init__(self, values=None):
        self.values = values or []

    def scalars(self):
        return self

    def all(self):
        return self.values


class _FakeDB:
    def __init__(self):
        self.insert_params = None

    def execute(self, statement, params=None):
        sql = str(statement)
        if "SELECT DISTINCT location_id" in sql:
            return _Result(["loc_branch_1"])
        if "INSERT INTO audit_events" in sql:
            self.insert_params = params
        return _Result()


def test_dataset_audit_event_adds_authoritative_branch_scope(monkeypatch):
    db = _FakeDB()

    class _SessionFactory:
        @contextmanager
        def begin(self):
            yield db

    monkeypatch.setattr(supabase_provider, "SessionLocal", _SessionFactory())
    monkeypatch.setattr(
        supabase_provider,
        "authorization_context",
        lambda claims, workspace_id: {
            "workspace_authorized": True,
            "organization_id": "org_1",
            "principal_id": "principal_1",
        },
    )
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")

    supabase_provider.audit_dataset_event(
        "workspace_1",
        "subject_1",
        "dataset.upload",
        "succeeded",
        metadata={"resource_id": "dataset_1"},
    )

    assert db.insert_params is not None
    metadata = json.loads(db.insert_params["metadata"])
    assert metadata["location_id"] == "loc_branch_1"
    assert metadata["organization_id"] == "org_1"
    assert metadata["workspace_id"] == "workspace_1"
    assert db.insert_params["action"] == "dataset.upload"
    assert db.insert_params["outcome"] == "succeeded"


def test_dataset_audit_write_failure_is_logged_without_swallowing_silently(monkeypatch, caplog):
    def fail_audit(*args, **kwargs):
        raise RuntimeError("sensitive database detail must not be logged")

    monkeypatch.setattr(dataset_service, "audit_dataset_event", fail_audit)

    with caplog.at_level(logging.ERROR, logger=dataset_service.__name__):
        dataset_service._audit_safely(
            "workspace_1",
            "subject_1",
            "dataset.delete",
            "succeeded",
            resource_id="dataset_1",
        )

    assert "dataset_audit_write_failed" in caplog.text
    assert "action=dataset.delete" in caplog.text
    assert "error_type=RuntimeError" in caplog.text
    assert "sensitive database detail must not be logged" not in caplog.text
