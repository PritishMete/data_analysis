# datasets/models.py
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TypeDecorator

from core.db import Base


class PortableJSON(TypeDecorator):
    """JSONB on PostgreSQL, JSON elsewhere so the existing SQLite test suite remains usable."""
    impl = JSON
    cache_ok = True

    def load_dialect_impl(self, dialect):
        if dialect.name == "postgresql":
            return dialect.type_descriptor(JSONB())
        return dialect.type_descriptor(JSON())


def _new_uuid() -> str:
    return str(uuid.uuid4())


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Dataset(Base):
    __tablename__ = "datasets"

    dataset_id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_uuid)
    organization_id: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    dataset_name: Mapped[str] = mapped_column(String(255), nullable=False)
    uploaded_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)
    schema_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    file_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    row_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    column_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    source_type: Mapped[str] = mapped_column(String(32), nullable=False)
    last_accessed: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)

    # Managed-dataset lifecycle metadata. Nullable on the additive migration
    # path so existing Dataset Registry records remain valid.
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="ready", index=True)
    original_filename: Mapped[str | None] = mapped_column(String(255), nullable=True)
    content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)
    file_size: Mapped[int | None] = mapped_column(Integer, nullable=True)
    storage_provider: Mapped[str | None] = mapped_column(String(64), nullable=True)
    storage_object_id: Mapped[str | None] = mapped_column(String(512), nullable=True)
    current_version_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    version_number: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    columns: Mapped[list["DatasetColumn"]] = relationship(
        "DatasetColumn", back_populates="dataset", cascade="all, delete-orphan"
    )
    versions: Mapped[list["DatasetVersion"]] = relationship(
        "DatasetVersion", back_populates="dataset", cascade="all, delete-orphan"
    )

    def __repr__(self) -> str:
        return f"<Dataset {self.dataset_id} '{self.dataset_name}' ({self.row_count}x{self.column_count})>"


class DatasetVersion(Base):
    __tablename__ = "dataset_versions"
    __table_args__ = (
        UniqueConstraint("dataset_id", "version_id", name="uq_dataset_version_label"),
        Index("ix_dataset_versions_dataset_created", "dataset_id", "created_at"),
    )

    version_pk: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_uuid)
    dataset_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("datasets.dataset_id", ondelete="CASCADE"), nullable=False, index=True
    )
    version_id: Mapped[str] = mapped_column(String(64), nullable=False)
    version_number: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="processing", index=True)
    file_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    schema_hash: Mapped[str] = mapped_column(String(64), nullable=False, default="")
    row_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    column_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    original_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)
    file_size: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    storage_provider: Mapped[str | None] = mapped_column(String(64), nullable=True)
    storage_object_id: Mapped[str | None] = mapped_column(String(512), nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)
    failure_reason: Mapped[str | None] = mapped_column(String(1000), nullable=True)

    dataset: Mapped["Dataset"] = relationship("Dataset", back_populates="versions")
    rows: Mapped[list["DatasetRow"]] = relationship(
        "DatasetRow", back_populates="version", cascade="all, delete-orphan"
    )


class DatasetRow(Base):
    __tablename__ = "dataset_rows"
    __table_args__ = (
        UniqueConstraint("version_pk", "row_number", name="uq_dataset_row_number"),
        Index("ix_dataset_rows_version_row", "version_pk", "row_number"),
    )

    row_id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    version_pk: Mapped[str] = mapped_column(
        String(36), ForeignKey("dataset_versions.version_pk", ondelete="CASCADE"), nullable=False, index=True
    )
    row_number: Mapped[int] = mapped_column(Integer, nullable=False)
    row_data: Mapped[dict] = mapped_column(PortableJSON(), nullable=False)

    version: Mapped["DatasetVersion"] = relationship("DatasetVersion", back_populates="rows")


class DatasetColumn(Base):
    __tablename__ = "dataset_columns"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    dataset_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("datasets.dataset_id", ondelete="CASCADE"), nullable=False, index=True
    )
    column_name: Mapped[str] = mapped_column(String(255), nullable=False)
    detected_type: Mapped[str] = mapped_column(String(32), nullable=False)
    nullable: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    unique_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    missing_percentage: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    inferred_role: Mapped[str | None] = mapped_column(String(32), nullable=True)
    inferred_role_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    inferred_role_evidence: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    role_detected_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    dataset: Mapped["Dataset"] = relationship("Dataset", back_populates="columns")
