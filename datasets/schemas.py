from datetime import datetime

from pydantic import BaseModel


class DatasetColumnOut(BaseModel):
    column_name: str
    detected_type: str
    nullable: bool
    unique_count: int
    missing_percentage: float
    inferred_role: str | None
    inferred_role_confidence: float | None = None
    inferred_role_evidence: dict | None = None
    role_detected_at: datetime | None = None

    model_config = {"from_attributes": True}


class DatasetVersionOut(BaseModel):
    version_id: str
    version_number: int
    status: str
    file_hash: str
    schema_hash: str
    row_count: int
    column_count: int
    original_filename: str
    file_size: int
    created_by: str | None
    created_at: datetime
    storage_provider: str | None
    storage_object_id: str | None

    model_config = {"from_attributes": True}


class DatasetOut(BaseModel):
    dataset_id: str
    organization_id: str
    dataset_name: str
    uploaded_by: str | None
    created_at: datetime
    schema_hash: str
    file_hash: str
    row_count: int
    column_count: int
    source_type: str
    last_accessed: datetime
    status: str = "ready"
    original_filename: str | None = None
    content_type: str | None = None
    file_size: int | None = None
    storage_provider: str | None = None
    storage_object_id: str | None = None
    current_version_id: str | None = None
    version_number: int = 1

    model_config = {"from_attributes": True}


class DatasetRegisterResponse(BaseModel):
    dataset: DatasetOut
    columns: list[DatasetColumnOut]
    was_duplicate: bool
