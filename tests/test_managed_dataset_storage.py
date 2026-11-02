import pytest

from dataset_storage import service
from dataset_storage.provider import SupabaseDatasetStorageProvider, archive_original_enabled


def test_storage_paths_are_traversal_safe(monkeypatch):
    provider = SupabaseDatasetStorageProvider(client=object())
    assert provider.object_path(
        organization_id="org_1", dataset_id="ds_abc123", version_id="v1"
    ) == "organizations/org_1/datasets/ds_abc123/versions/v1/original.csv"
    with pytest.raises(ValueError):
        provider.object_path(
            organization_id="../org", dataset_id="ds_1", version_id="v1"
        )


def test_managed_filename_is_csv_only():
    assert service._safe_filename("financial-risk.csv") == "financial-risk.csv"
    with pytest.raises(ValueError):
        service._safe_filename("financial-risk.xlsx")
    with pytest.raises(ValueError):
        service._safe_filename("../financial-risk.csv")


def test_original_archive_is_opt_in(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL", "false")
    assert archive_original_enabled() is False
    monkeypatch.setenv("INSIGHTFLOW_DATASET_ARCHIVE_ORIGINAL", "true")
    assert archive_original_enabled() is True


def test_employee_roles_do_not_receive_dataset_upload():
    from firebase_authz.schema import DEFAULT_ROLES

    for role in ("external_viewer", "employee", "team_lead"):
        assert "dataset.upload" not in DEFAULT_ROLES[role]


def test_no_public_download_url_is_returned():
    from dataset_storage.routes import router

    route = next(item for item in router.routes if item.path.endswith("/download"))
    assert route.path == "/v1/managed-datasets/{dataset_id}/download"

def test_dataset_display_name_is_validated_and_defaults_to_filename():
    assert service._safe_dataset_name("Retail Sales 2026", "retail_sales.csv") == "Retail Sales 2026"
    assert service._safe_dataset_name(None, "retail_sales.csv") == "retail_sales"
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("   ", "retail_sales.csv")
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("bad\nname", "retail_sales.csv")
    with pytest.raises(ValueError, match="Dataset name"):
        service._safe_dataset_name("x" * 256, "retail_sales.csv")



def test_duplicate_dataset_upload_conflict_is_a_confirmable_http_409():
    from dataset_storage.routes import _map_error
    from dataset_storage.service import DatasetUploadConflict

    conflict = DatasetUploadConflict([
        {
            "dataset_id": "existing-dataset",
            "dataset_name": "Retail Sales 2026",
            "original_filename": "retail.csv",
            "reason": "name",
        }
    ])
    response = _map_error(conflict)
    assert response.status_code == 409
    assert response.detail["code"] == "dataset_duplicate"
    assert response.detail["conflicts"][0]["dataset_id"] == "existing-dataset"


def test_managed_upload_route_accepts_dataset_name_and_replacement_target():
    from dataset_storage.routes import router

    route = next(item for item in router.routes if item.path == "/v1/managed-datasets" and "POST" in item.methods)
    import inspect
    parameters = inspect.signature(route.endpoint).parameters
    assert "dataset_name" in parameters
    assert "replace_dataset_id" in parameters



def test_duplicate_detection_checks_ready_version_hashes_and_explicit_target():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    assert "DatasetVersion.file_hash == incoming_hash" in source
    assert 'DatasetVersion.status == "ready"' in source
    assert "def _single_replacement_target" in source
    assert "replacement_target != replace_dataset_id" in source
    assert "replace_dataset_id is None and conflicts" in source





def test_branch_scoped_roles_only_receive_duplicate_matches_in_their_branch():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    assert 'if "organization_owner" not in set(context.get("role_ids", []))' in source
    assert "FROM dataset_authorization da" in source
    assert "da.location_id = :duplicate_location_id" in source
    assert "da.protected_original IS TRUE" in source



def test_existing_dataset_version_requires_explicit_identical_content_confirmation():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    assert "DatasetVersion.dataset_id == dataset_id" in source
    assert "matching_version is not None and not confirm_duplicate" in source
    assert '"reasons": ["content"]' in source

    from dataset_storage.routes import router
    import inspect

    version_route = next(
        item for item in router.routes
        if item.path == "/v1/managed-datasets/{dataset_id}/versions"
    )
    assert "confirm_duplicate" in inspect.signature(version_route.endpoint).parameters



def test_duplicate_preflight_rejects_invalid_hash_without_uploading_file():
    with pytest.raises(ValueError, match="SHA-256"):
        service.check_managed_dataset_duplicates(
            workspace_id="workspace",
            token="unused",
            file_sha256="not-a-sha256-hash",
            dataset_name="Monthly sales",
        )


def test_duplicate_preflight_route_is_registered():
    from dataset_storage.routes import router
    import inspect

    route = next(
        item for item in router.routes
        if item.path == "/v1/managed-datasets/duplicate-check"
        and "POST" in item.methods
    )
    parameters = inspect.signature(route.endpoint).parameters
    assert "body" in parameters
    assert "authorization" in parameters
    assert "workspace_id" in parameters
    assert "location_id" in parameters



def test_stale_upload_recovery_preserves_complete_physical_data():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    helper_start = source.index("def _physical_upload_is_complete")
    recovery_start = source.index("def _recover_stale_processing_uploads")
    lock_start = source.index("def _lock_active_upload_assignment", recovery_start)
    helper = source[helper_start:recovery_start]
    recovery = source[recovery_start:lock_start]

    # Recovery must prove row count, contiguous unique row numbers, and schema
    # consistency before publishing READY; complete physical rows must not be
    # dropped just because finalization was interrupted.
    assert "COUNT(*) AS row_count" in helper
    assert 'MIN("{ROW_NUMBER_COLUMN}") AS min_row' in helper
    assert 'MAX("{ROW_NUMBER_COLUMN}") AS max_row' in helper
    assert 'COUNT(DISTINCT "{ROW_NUMBER_COLUMN}") AS distinct_rows' in helper
    assert "information_schema.columns" in helper
    assert "if ROW_NUMBER_COLUMN not in all_physical_columns" in helper
    assert "metadata_columns" in helper
    assert "_physical_upload_is_complete(repo, version)" in recovery
    assert 'version.status = "ready"' in recovery
    assert "dataset.current_version_id = version.version_id" in recovery
    assert recovery.index("_physical_upload_is_complete(repo, version)") < recovery.index(
        "drop_physical_table"
    )



def test_stale_recovery_cleans_orphaned_proposal_candidates_but_never_publishes_them():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    recovery_start = source.index("def _recover_stale_processing_uploads")
    lock_start = source.index("def _lock_active_upload_assignment", recovery_start)
    recovery = source[recovery_start:lock_start]

    # Pending proposals are excluded by the candidate query. An orphan p-prefixed
    # candidate without a pending proposal must be cleaned, not skipped forever
    # and never auto-published as an official dataset version.
    assert "dataset_change_proposals.status = 'pending'" in recovery
    assert 'not str(version.version_id).startswith("p")' in recovery
    assert recovery.index('not str(version.version_id).startswith("p")') < recovery.index(
        "_physical_upload_is_complete(repo, version)"
    )
    assert 'version.status = "failed"' in recovery

def test_csv_validation_accepts_large_text_fields_within_upload_limit():
    import io

    payload = b"id,description\n1," + (b"x" * 200_000) + b"\n"
    columns = service.DatasetRegistryService._validate_csv_structure(io.BytesIO(payload))
    assert columns == ["id", "description"]


def test_csv_validation_rejects_malformed_quoting():
    import io

    payload = b'id,description\n1,"unterminated\n'
    with pytest.raises(ValueError, match="could not be parsed safely"):
        service.DatasetRegistryService._validate_csv_structure(io.BytesIO(payload))


def test_csv_validation_rejects_inconsistent_row_width():
    import io

    payload = b"id,name\n1,valid\n2,extra,column\n"
    with pytest.raises(ValueError, match="row 3 has 3 fields; expected 2"):
        service.DatasetRegistryService._validate_csv_structure(io.BytesIO(payload))



def test_managed_dataset_schema_enforces_version_and_column_uniqueness():
    from datasets.models import DatasetColumn, DatasetVersion
    from sqlalchemy import UniqueConstraint

    version_unique_pairs = {
        tuple(column.name for column in constraint.columns)
        for constraint in DatasetVersion.__table__.constraints
        if isinstance(constraint, UniqueConstraint)
    }
    assert ("dataset_id", "version_number") in version_unique_pairs

    column_indexes = {
        index.name: index
        for index in DatasetColumn.__table__.indexes
    }
    assert "uq_dataset_columns_version_name" in column_indexes
    assert column_indexes["uq_dataset_columns_version_name"].unique is True


def test_managed_dataset_integrity_migration_guards_references_and_duplicates():
    from pathlib import Path

    migration = Path("migrations/0035_managed_dataset_integrity.sql").read_text()
    assert "uq_dataset_version_number" in migration
    assert "uq_dataset_columns_version_name" in migration
    assert "fk_dataset_current_version" in migration
    assert "fk_dataset_column_version_owner" in migration
    assert "HAVING COUNT(*) > 1" in migration
    assert "Cannot add managed-dataset integrity constraints" in migration


def test_managed_dataset_deletion_preserves_version_metadata_and_removes_rows():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    delete_start = source.index("def delete_managed_dataset(")
    delete_end = source.index("def create_managed_working_copy(", delete_start)
    deletion = source[delete_start:delete_end]

    assert 'version.status = "deleted"' in deletion
    assert "delete(DatasetRow)" in deletion
    assert "drop_physical_table" in deletion
    assert 'locked_dataset.status = "deleted"' in deletion
    assert 'locked_dataset.current_version_id = None' in deletion
    assert "repo.delete_dataset(dataset_id)" not in deletion
    assert '"history_preserved": True' in deletion
    assert "status = 'stale'" in deletion


def test_deleted_managed_dataset_is_denied_even_if_an_acl_is_stale():
    from pathlib import Path

    source = Path("dataset_storage/service.py").read_text()
    start = source.index("def _authorize_dataset(")
    end = source.index("def _audit_safely(", start)
    helper = source[start:end]

    assert 'dataset.status in {"deleted", "deleting"}' in helper
    assert 'raise FileNotFoundError("Dataset not found.")' in helper

def test_csv_validation_rejects_headers_that_collide_after_normalization():
    import io

    payload = b"Name,name,other\n1,2,3\n"
    with pytest.raises(ValueError, match="ambiguous duplicate column names"):
        service.DatasetRegistryService._validate_csv_structure(io.BytesIO(payload))


def test_csv_validation_preserves_reserved_row_number_header_as_source_data():
    import io

    payload = b"__ row_number,name\n42,example\n"
    columns = service.DatasetRegistryService._validate_csv_structure(io.BytesIO(payload))
    assert columns == ["source_row_number", "name"]

