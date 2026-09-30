from __future__ import annotations

import csv
import hashlib
import io
import itertools
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import BinaryIO

import pandas as pd

from .hashing import compute_file_hash, compute_schema_hash
from .models import Dataset, DatasetColumn, DatasetVersion
from .repository import DatasetRepository


DEFAULT_CHUNK_ROWS = int(os.getenv("INSIGHTFLOW_DATASET_CHUNK_ROWS", "5000"))
MAX_COLUMNS = int(os.getenv("INSIGHTFLOW_MANAGED_DATASET_MAX_COLUMNS", "200"))
SAMPLE_ROWS = int(os.getenv("INSIGHTFLOW_SCHEMA_SAMPLE_ROWS", "10000"))


def _json_value(value):
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    if isinstance(value, (pd.Timestamp, datetime)):
        return value.isoformat()
    if hasattr(value, "item"):
        value = value.item()
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def _logical_type(series: pd.Series) -> str:
    dtype = series.dtype
    if pd.api.types.is_bool_dtype(dtype):
        return "boolean"
    if pd.api.types.is_integer_dtype(dtype):
        return "integer"
    if pd.api.types.is_float_dtype(dtype):
        return "decimal"
    if pd.api.types.is_datetime64_any_dtype(dtype):
        return "datetime"
    values = series.dropna().astype(str).head(1000)
    if not values.empty:
        lower = values.str.strip().str.lower()
        if lower.isin({"true", "false", "yes", "no"}).all():
            return "boolean"
        if lower.str.contains(r"[-/:]", regex=True).mean() >= 0.8:
            parsed = pd.to_datetime(values, errors="coerce")
            if parsed.notna().mean() >= 0.95:
                return "datetime"
    return "text"


def _merge_types(current: str | None, incoming: str) -> str:
    if not current or current == incoming:
        return incoming
    if {current, incoming} <= {"integer", "decimal"}:
        return "decimal"
    if current == "boolean" or incoming == "boolean":
        return "text"
    if current == "datetime" or incoming == "datetime":
        return "text"
    return "text"


@dataclass
class DatasetRegistration:
    dataset: Dataset
    columns: list[DatasetColumn]
    was_duplicate: bool


@dataclass
class StreamingDatasetRegistration:
    registration: DatasetRegistration
    version: DatasetVersion
    sample: pd.DataFrame


class DatasetRegistryService:
    def __init__(self, repository: DatasetRepository):
        self.repository = repository

    def register_dataset(
        self,
        *,
        df: pd.DataFrame,
        raw_bytes: bytes,
        organization_id: str,
        dataset_name: str,
        uploaded_by: str | None,
        source_type: str,
    ) -> DatasetRegistration:
        file_hash = compute_file_hash(raw_bytes)
        existing = self.repository.find_by_file_hash(file_hash, organization_id)
        if existing is not None and existing.status not in {"failed", "deleted"}:
            self.repository.touch_last_accessed(existing.dataset_id)
            return DatasetRegistration(
                existing, self.repository.get_columns(existing.dataset_id), True
            )

        schema_hash = compute_schema_hash((str(col), str(df[col].dtype)) for col in df.columns)
        now = datetime.now(timezone.utc)
        with self.repository.db.begin():
            dataset = Dataset(
                organization_id=organization_id,
                dataset_name=dataset_name,
                uploaded_by=uploaded_by,
                schema_hash=schema_hash,
                file_hash=file_hash,
                row_count=int(len(df)),
                column_count=int(len(df.columns)),
                source_type=source_type,
                status="ready",
                original_filename=dataset_name,
                file_size=len(raw_bytes),
                content_type="text/csv" if source_type == "csv" else None,
                version_number=1,
                current_version_id="v1",
                created_at=now,
                last_accessed=now,
            )
            self.repository.create_dataset(dataset, commit=False)
            version = DatasetVersion(
                dataset_id=dataset.dataset_id,
                version_id="v1",
                version_number=1,
                status="ready",
                file_hash=file_hash,
                schema_hash=schema_hash,
                row_count=len(df),
                column_count=len(df.columns),
                original_filename=dataset_name,
                file_size=len(raw_bytes),
                created_by=uploaded_by,
                created_at=now,
            )
            self.repository.add_version(version, commit=False)
            columns = [
                self._build_column_row(dataset.dataset_id, df, col, version.version_pk)
                for col in df.columns
            ]
            self.repository.add_columns(columns, commit=False)
            self.repository.bulk_add_rows(
                version.version_pk,
                [
                    {
                        "row_number": index + 1,
                        "row_data": {
                            str(k): _json_value(v) for k, v in row.items()
                        },
                    }
                    for index, row in enumerate(df.to_dict(orient="records"))
                ],
            )
        return DatasetRegistration(dataset, columns, False)

    @staticmethod
    def _validate_csv_structure(file_obj: BinaryIO) -> list[str]:
        file_obj.seek(0)
        text_stream = io.TextIOWrapper(file_obj, encoding="utf-8-sig", newline="")
        try:
            reader = csv.reader(text_stream, strict=True)
            header = next(reader, None)
            if not header or any(not str(column).strip() for column in header):
                raise ValueError("CSV header must contain named columns.")
            columns = [str(column) for column in header]
            if len(columns) > MAX_COLUMNS:
                raise ValueError(f"CSV has too many columns; maximum is {MAX_COLUMNS}.")
            if len(set(columns)) != len(columns):
                raise ValueError("CSV contains duplicate column names.")
            for row_number, row in enumerate(reader, start=2):
                if len(row) != len(columns):
                    raise ValueError(
                        f"CSV row {row_number} has {len(row)} fields; expected {len(columns)}."
                    )
            return columns
        except csv.Error as exc:
            raise ValueError(f"CSV could not be parsed safely: {exc}") from exc
        finally:
            text_stream.detach()
            file_obj.seek(0)

    def register_csv_stream(
        self,
        *,
        file_obj: BinaryIO,
        filename: str,
        organization_id: str,
        dataset_name: str,
        uploaded_by: str | None,
        existing_dataset_id: str | None = None,
        content_type: str | None = None,
        max_bytes: int,
        chunk_rows: int = DEFAULT_CHUNK_ROWS,
    ) -> StreamingDatasetRegistration:
        safe_name = os.path.basename(str(filename or "").replace("\\", "/")).strip()
        if (
            not safe_name
            or len(safe_name) > 255
            or not safe_name.lower().endswith(".csv")
            or any(ord(char) < 32 or ord(char) == 127 for char in safe_name)
        ):
            raise ValueError("Only safe CSV files are accepted as managed datasets.")

        file_hash, file_size = self._hash_stream(file_obj, max_bytes)
        existing = None
        if existing_dataset_id is None:
            existing = self.repository.find_by_file_hash(file_hash, organization_id)
            if existing is not None and existing.status not in {"failed", "deleted"}:
                version = self.repository.get_version(existing.dataset_id)
                if version is None or version.status != "ready":
                    raise ValueError("Duplicate dataset has no READY current version.")
                self.repository.touch_last_accessed(existing.dataset_id)
                return StreamingDatasetRegistration(
                    DatasetRegistration(
                        existing,
                        self.repository.get_columns_for_version(version.version_pk),
                        True,
                    ),
                    version,
                    pd.DataFrame(),
                )
        else:
            existing = self.repository.get_by_id(existing_dataset_id)
            if existing is None or existing.organization_id != organization_id:
                raise ValueError("Dataset is not accessible in this organization.")
            if existing.status == "deleted":
                raise ValueError("This dataset cannot receive a new version.")
            current = self.repository.get_version(existing.dataset_id)
            if current is not None and current.file_hash == file_hash:
                self.repository.touch_last_accessed(existing.dataset_id)
                return StreamingDatasetRegistration(
                    DatasetRegistration(
                        existing,
                        self.repository.get_columns_for_version(current.version_pk),
                        True,
                    ),
                    current,
                    pd.DataFrame(),
                )

        expected_columns = self._validate_csv_structure(file_obj)

        file_obj.seek(0)
        try:
            chunks = pd.read_csv(
                file_obj,
                chunksize=max(100, chunk_rows),
                encoding="utf-8-sig",
                on_bad_lines="error",
            )
            first = next(chunks)
        except StopIteration as exc:
            raise ValueError("CSV must contain at least one data row.") from exc
        except pd.errors.EmptyDataError as exc:
            raise ValueError("CSV is empty or has no header.") from exc
        except (pd.errors.ParserError, UnicodeDecodeError) as exc:
            raise ValueError(f"CSV could not be parsed safely: {exc}") from exc

        columns = [str(column) for column in first.columns]
        if columns != expected_columns:
            raise ValueError("CSV header could not be parsed consistently.")

        is_version = existing is not None
        version_number = existing.version_number + 1 if is_version else 1
        sample_frames: list[pd.DataFrame] = []
        sample_count = 0
        type_map: dict[str, str] = {}
        missing: dict[str, int] = {column: 0 for column in columns}
        row_count = 0

        # Hash/deduplication and current-version lookups above trigger
        # SQLAlchemy autobegin. End that read-only transaction before opening
        # the single atomic ingestion transaction.
        self.repository.db.rollback()

        # One transaction owns the entire structured ingestion. A parse,
        # profiling, or bulk-write error therefore rolls back every row/version
        # instead of leaving a partial dataset behind.
        with self.repository.db.begin():
            if is_version:
                dataset = existing
            else:
                dataset = Dataset(
                    organization_id=organization_id,
                    dataset_name=dataset_name,
                    uploaded_by=uploaded_by,
                    schema_hash="",
                    file_hash=file_hash,
                    row_count=0,
                    column_count=len(columns),
                    source_type="csv",
                    status="processing",
                    original_filename=safe_name,
                    content_type=content_type or "text/csv",
                    file_size=file_size,
                    version_number=1,
                    current_version_id=None,
                )
                self.repository.create_dataset(dataset, commit=False)

            version = DatasetVersion(
                dataset_id=dataset.dataset_id,
                version_id=f"v{version_number}",
                version_number=version_number,
                status="processing",
                file_hash=file_hash,
                schema_hash="",
                row_count=0,
                column_count=len(columns),
                original_filename=safe_name,
                content_type=content_type or "text/csv",
                file_size=file_size,
                created_by=uploaded_by,
            )
            self.repository.add_version(version, commit=False)

            for chunk in itertools.chain((first,), chunks):
                chunk_columns = [str(c) for c in chunk.columns]
                if chunk_columns != columns:
                    raise ValueError("CSV rows do not have a consistent column structure.")
                added, sample = self._prepare_chunk(
                    chunk, row_count, type_map, missing, sample_count, SAMPLE_ROWS
                )
                self.repository.bulk_add_rows(version.version_pk, added)
                row_count += len(added)
                if sample is not None:
                    sample_frames.append(sample)
                    sample_count += len(sample)

            if row_count <= 0:
                raise ValueError("CSV must contain at least one data row.")

            schema_hash = compute_schema_hash(type_map.items())
            column_rows = [
                DatasetColumn(
                    dataset_id=dataset.dataset_id,
                    version_pk=version.version_pk,
                    column_name=column,
                    detected_type=type_map.get(column, "text"),
                    nullable=missing[column] > 0,
                    unique_count=self.repository.count_distinct_row_values(
                        version.version_pk, column
                    ),
                    missing_percentage=round((missing[column] / row_count) * 100.0, 4),
                )
                for column in columns
            ]
            self.repository.add_columns(column_rows, commit=False)

            version.schema_hash = schema_hash
            version.row_count = row_count
            version.status = "processing"
            self.repository.db.flush()

            if not is_version:
                dataset.schema_hash = schema_hash
                dataset.file_hash = file_hash
                dataset.row_count = row_count
                dataset.column_count = len(columns)
                dataset.version_number = version_number
                dataset.original_filename = safe_name
                dataset.content_type = content_type or "text/csv"
                dataset.file_size = file_size
                dataset.status = "processing"

        sample = (
            pd.concat(sample_frames, ignore_index=True)
            if sample_frames
            else first.head(0)
        )
        return StreamingDatasetRegistration(
            DatasetRegistration(dataset, column_rows, False),
            version,
            sample,
        )

    def finalize_version(
        self,
        dataset_id: str,
        version_id: str,
        *,
        storage_provider: str | None = None,
        storage_object_id: str | None = None,
    ) -> Dataset:
        with self.repository.db.begin():
            dataset = self.repository.get_by_id(dataset_id)
            version = self.repository.get_version(dataset_id, version_id)
            if dataset is None or version is None:
                raise ValueError("Dataset version does not exist.")
            if version.status != "processing":
                raise ValueError("Only a PROCESSING version can become READY.")
            version.status = "ready"
            version.storage_provider = storage_provider
            version.storage_object_id = storage_object_id
            dataset.status = "ready"
            dataset.current_version_id = version.version_id
            dataset.version_number = version.version_number
            dataset.schema_hash = version.schema_hash
            dataset.file_hash = version.file_hash
            dataset.row_count = version.row_count
            dataset.column_count = version.column_count
            dataset.original_filename = version.original_filename
            dataset.content_type = version.content_type
            dataset.file_size = version.file_size
            dataset.storage_provider = storage_provider
            dataset.storage_object_id = storage_object_id
            dataset.last_accessed = datetime.now(timezone.utc)
            self.repository.db.flush()
        return dataset

    def mark_failed(self, dataset_id: str, version_id: str, reason: str) -> None:
        with self.repository.db.begin():
            version = self.repository.get_version(dataset_id, version_id)
            dataset = self.repository.get_by_id(dataset_id)
            if version is not None:
                version.status = "failed"
                version.failure_reason = str(reason)[:1000]
            if dataset is not None and dataset.current_version_id is None:
                dataset.status = "failed"
            self.repository.db.flush()

    @staticmethod
    def _prepare_chunk(
        chunk: pd.DataFrame,
        current_row_count: int,
        type_map: dict[str, str],
        missing: dict[str, int],
        sample_count: int,
        sample_limit: int,
    ) -> tuple[list[dict], pd.DataFrame | None]:
        rows = []
        for column in chunk.columns:
            name = str(column)
            missing[name] += int(chunk[name].isna().sum())
            type_map[name] = _merge_types(type_map.get(name), _logical_type(chunk[name]))
        for row_offset, record in enumerate(
            chunk.to_dict(orient="records"), start=1
        ):
            rows.append({
                "row_number": current_row_count + row_offset,
                "row_data": {
                    str(key): _json_value(value) for key, value in record.items()
                },
            })
        remaining = max(0, sample_limit - sample_count)
        sample = chunk.head(remaining).copy() if remaining else None
        return rows, sample

    @staticmethod
    def _build_column_row(
        dataset_id: str,
        df: pd.DataFrame,
        column_name: str,
        version_pk: str,
    ) -> DatasetColumn:
        series = df[column_name]
        row_count = len(series)
        missing_count = int(series.isnull().sum())
        return DatasetColumn(
            dataset_id=dataset_id,
            version_pk=version_pk,
            column_name=str(column_name),
            detected_type=str(series.dtype),
            nullable=missing_count > 0,
            unique_count=int(series.nunique(dropna=True)),
            missing_percentage=round(
                (missing_count / row_count * 100.0), 4
            ) if row_count else 0.0,
            inferred_role=None,
        )

    @staticmethod
    def _hash_stream(file_obj: BinaryIO, max_bytes: int) -> tuple[str, int]:
        digest = hashlib.sha256()
        total = 0
        file_obj.seek(0)
        while True:
            chunk = file_obj.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError(
                    f"Dataset exceeds the configured {max_bytes} byte limit."
                )
            digest.update(chunk)
        file_obj.seek(0)
        if total == 0:
            raise ValueError("Dataset file is empty.")
        return digest.hexdigest(), total
