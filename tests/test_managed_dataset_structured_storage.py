from io import BytesIO

import pandas as pd
import pytest

from datasets.repository import DatasetRepository
from datasets.service import DatasetRegistryService
from datasets.models import DatasetRow


def csv_bytes(rows: int = 3, offset: int = 0) -> bytes:
    lines = ["id,amount,active,date,note"]
    for i in range(rows):
        n = i + offset
        lines.append(f"{n},{n * 1.5},{'true' if n % 2 else 'false'},2026-01-{(n % 28) + 1:02d},note-{n}")
    return ("\n".join(lines) + "\n").encode()


def register(service, db, raw, org="org_1", dataset_id=None, chunk_rows=2):
    result = service.register_csv_stream(
        file_obj=BytesIO(raw),
        filename="financial_risk.csv",
        organization_id=org,
        dataset_name="financial_risk.csv",
        uploaded_by="principal_1",
        existing_dataset_id=dataset_id,
        content_type="text/csv",
        max_bytes=20 * 1024 * 1024,
        chunk_rows=chunk_rows,
    )
    return result


def test_csv_rows_are_persisted_and_profiled(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    result = register(service, db_session, csv_bytes(4))
    assert result.registration.was_duplicate is False
    assert result.registration.dataset.status == "processing"
    assert result.version.row_count == 4
    assert result.version.version_id == "v1"
    rows = DatasetRepository(db_session).get_rows(result.version.version_pk, limit=10)
    assert len(rows) == 4
    assert rows[0].row_data["id"] == 0
    assert rows[1].row_data["active"] is True
    columns = DatasetRepository(db_session).get_columns_for_version(result.version.version_pk)
    assert {c.column_name for c in columns} == {"id", "amount", "active", "date", "note"}
    id_column = next(c for c in columns if c.column_name == "id")
    assert id_column.detected_type == "integer"
    assert id_column.missing_count == 0
    assert id_column.missing_percentage == 0.0


def test_exact_duplicate_is_idempotent_per_organization(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    first = register(service, db_session, csv_bytes(3))
    service.finalize_version(first.registration.dataset.dataset_id, first.version.version_id)
    second = register(service, db_session, csv_bytes(3))
    assert second.registration.was_duplicate is True
    assert second.registration.dataset.dataset_id == first.registration.dataset.dataset_id
    assert len(DatasetRepository(db_session).list_by_organization("org_1")) == 1


def test_same_file_in_two_organizations_is_isolated(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    a = register(service, db_session, csv_bytes(3), "org_a")
    b = register(service, db_session, csv_bytes(3), "org_b")
    assert a.registration.dataset.dataset_id != b.registration.dataset.dataset_id
    assert a.registration.dataset.organization_id == "org_a"
    assert b.registration.dataset.organization_id == "org_b"


def test_new_version_preserves_previous_rows(db_session):
    repo = DatasetRepository(db_session)
    service = DatasetRegistryService(repo)
    first = register(service, db_session, csv_bytes(3))
    service.finalize_version(first.registration.dataset.dataset_id, first.version.version_id)
    second = register(service, db_session, csv_bytes(4, offset=100), dataset_id=first.registration.dataset.dataset_id)
    assert second.version.version_id == "v2"
    versions = repo.list_versions(first.registration.dataset.dataset_id)
    assert [v.version_id for v in versions] == ["v1", "v2"]
    assert repo.count_rows(versions[0].version_pk) == 3
    assert repo.count_rows(versions[1].version_pk) == 4
    assert all(column.version_pk == versions[0].version_pk for column in repo.get_columns_for_version(versions[0].version_pk))
    assert all(column.version_pk == versions[1].version_pk for column in repo.get_columns_for_version(versions[1].version_pk))


def test_malformed_csv_does_not_create_dataset(db_session):
    repo = DatasetRepository(db_session)
    service = DatasetRegistryService(repo)
    with pytest.raises(ValueError):
        register(service, db_session, b"id,amount\n1,10\n2,\"unterminated\n")
    assert repo.list_by_organization("org_1") == []




def test_missing_header_is_rejected(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    with pytest.raises(ValueError, match="header"):
        register(service, db_session, b",amount\n1,10\n")
    assert DatasetRepository(db_session).list_by_organization("org_1") == []


def test_inconsistent_row_width_is_rejected(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    with pytest.raises(ValueError, match="row 3"):
        register(service, db_session, b"id,amount\n1,10\n2\n")
    assert DatasetRepository(db_session).list_by_organization("org_1") == []


def test_unsupported_extension_is_rejected(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    with pytest.raises(ValueError, match="CSV"):
        service.register_csv_stream(
            file_obj=BytesIO(b"id\n1\n"),
            filename="financial_risk.xlsx",
            organization_id="org_1",
            dataset_name="financial_risk.xlsx",
            uploaded_by="principal_1",
            max_bytes=1000,
        )


def test_empty_csv_is_rejected(db_session):
    service = DatasetRegistryService(DatasetRepository(db_session))
    with pytest.raises(ValueError):
        register(service, db_session, b"id,amount\n")
    assert DatasetRepository(db_session).list_by_organization("org_1") == []


def test_failed_chunk_rolls_back_all_rows(db_session, monkeypatch):
    repo = DatasetRepository(db_session)
    service = DatasetRegistryService(repo)
    original = repo.bulk_add_rows
    calls = {"count": 0}

    def failing(version_pk, rows, **kwargs):
        calls["count"] += 1
        if calls["count"] == 2:
            raise RuntimeError("simulated database failure")
        return original(version_pk, rows, **kwargs)

    monkeypatch.setattr(repo, "bulk_add_rows", failing)
    with pytest.raises(RuntimeError):
        register(service, db_session, csv_bytes(5), chunk_rows=2)
    assert repo.list_by_organization("org_1") == []
    assert db_session.query(DatasetRow).count() == 0


def test_chunked_ingestion_uses_bulk_batches_for_200k_rows(db_session):
    repo = DatasetRepository(db_session)
    service = DatasetRegistryService(repo)
    raw = csv_bytes(200_000)
    calls = {"count": 0}
    original = repo.bulk_add_rows

    def counting(version_pk, rows, **kwargs):
        calls["count"] += 1
        assert len(rows) <= 5000
        return original(version_pk, rows, **kwargs)

    # The service receives one DataFrame chunk and sends one executemany-style
    # batch to SQL for each chunk; it never executes one INSERT per row.
    repo.bulk_add_rows = counting
    result = register(service, db_session, raw, chunk_rows=5000)
    assert result.version.row_count == 200_000
    assert calls["count"] >= 40
    assert repo.count_rows(result.version.version_pk) == 200_000


def test_delete_cascades_structured_rows(db_session):
    repo = DatasetRepository(db_session)
    service = DatasetRegistryService(repo)
    result = register(service, db_session, csv_bytes(10))
    dataset_id = result.registration.dataset.dataset_id
    repo.delete_dataset(dataset_id)
    assert repo.get_by_id(dataset_id) is None
    assert db_session.query(DatasetRow).count() == 0
