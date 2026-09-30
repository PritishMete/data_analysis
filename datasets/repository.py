from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import delete, func, insert, select
from sqlalchemy.schema import Table
from sqlalchemy.orm import Session

from .models import Dataset, DatasetColumn, DatasetRow, DatasetVersion


class DatasetRepository:
    def __init__(self, db: Session):
        self.db = db

    def create_dataset(self, dataset: Dataset, *, commit: bool = True) -> Dataset:
        self.db.add(dataset)
        self.db.flush()
        if commit:
            self.db.commit()
            self.db.refresh(dataset)
        return dataset

    def add_version(self, version: DatasetVersion, *, commit: bool = True) -> DatasetVersion:
        self.db.add(version)
        self.db.flush()
        if commit:
            self.db.commit()
            self.db.refresh(version)
        return version

    def add_columns(self, columns: list[DatasetColumn], *, commit: bool = True) -> list[DatasetColumn]:
        self.db.add_all(columns)
        self.db.flush()
        if commit:
            self.db.commit()
            for column in columns:
                self.db.refresh(column)
        return columns

    def bulk_add_rows(
        self,
        version_pk: str,
        rows: list[dict],
        *,
        table_name: str | None = None,
        columns: list[tuple[str, str]] | None = None,
        commit: bool = False,
    ) -> int:
        if not rows:
            return 0
        if table_name and columns:
            from .physical_table import build_physical_table, normalize_record

            table = build_physical_table(table_name, columns)
            payload = [
                normalize_record(
                    row["row_data"],
                    columns,
                    int(row["row_number"]),
                )
                for row in rows
            ]
            connection = self.db.connection()
            if connection.dialect.name == "postgresql":
                import csv
                import io
                raw = connection.connection.dbapi_connection
                preparer = connection.dialect.identifier_preparer
                quoted_table = (
                    f"{preparer.quote(table.schema)}."
                    f"{preparer.quote(table.name)}"
                )
                column_names = [
                    "__row_number",
                    *[name for name, _ in columns],
                ]
                quoted_columns = ", ".join(preparer.quote(name) for name in column_names)
                with raw.cursor() as cursor:
                    with cursor.copy(
                        f"COPY {quoted_table} ({quoted_columns}) "
                        "FROM STDIN WITH (FORMAT CSV)"
                    ) as copy:
                        buffer = io.StringIO()
                        writer = csv.writer(buffer, lineterminator="\\n")
                        for item in payload:
                            writer.writerow([item[name] for name in column_names])
                            if buffer.tell() >= 1024 * 1024:
                                copy.write(buffer.getvalue())
                                buffer.seek(0)
                                buffer.truncate(0)
                        if buffer.tell():
                            copy.write(buffer.getvalue())
            else:
                self.db.execute(table.insert(), payload)
        else:
            payload = [
                {
                    "version_pk": version_pk,
                    "row_number": int(row["row_number"]),
                    "row_data": row["row_data"],
                }
                for row in rows
            ]
            self.db.execute(insert(DatasetRow), payload)
        if commit:
            self.db.commit()
        return len(rows)

    def touch_last_accessed(self, dataset_id: str) -> None:
        dataset = self.get_by_id(dataset_id)
        if dataset is not None:
            dataset.last_accessed = datetime.now(timezone.utc)
            self.db.commit()

    def update_dataset(self, dataset_id: str, *, commit: bool = True, **values) -> Dataset:
        dataset = self.get_by_id(dataset_id)
        if dataset is None:
            raise KeyError(dataset_id)
        for key, value in values.items():
            setattr(dataset, key, value)
        self.db.flush()
        if commit:
            self.db.commit()
            self.db.refresh(dataset)
        return dataset

    def update_version(self, version_pk: str, *, commit: bool = True, **values) -> DatasetVersion:
        version = self.db.get(DatasetVersion, version_pk)
        if version is None:
            raise KeyError(version_pk)
        for key, value in values.items():
            setattr(version, key, value)
        self.db.flush()
        if commit:
            self.db.commit()
            self.db.refresh(version)
        return version

    def update_column_role(
        self,
        dataset_id: str,
        column_name: str,
        inferred_role: str | None,
        *,
        version_pk: str | None = None,
    ) -> None:
        conditions = [
            DatasetColumn.dataset_id == dataset_id,
            DatasetColumn.column_name == column_name,
        ]
        if version_pk is not None:
            conditions.append(DatasetColumn.version_pk == version_pk)
        stmt = select(DatasetColumn).where(*conditions)
        column = self.db.execute(stmt).scalars().first()
        if column is not None:
            column.inferred_role = inferred_role
            self.db.commit()

    def update_column_role_metadata(
        self,
        dataset_id: str,
        column_name: str,
        *,
        confidence: float | None,
        evidence: dict | None = None,
        detected_at: datetime | None = None,
        version_pk: str | None = None,
    ) -> None:
        conditions = [
            DatasetColumn.dataset_id == dataset_id,
            DatasetColumn.column_name == column_name,
        ]
        if version_pk is not None:
            conditions.append(DatasetColumn.version_pk == version_pk)
        stmt = select(DatasetColumn).where(*conditions)
        column = self.db.execute(stmt).scalars().first()
        if column is not None:
            column.inferred_role_confidence = confidence
            column.inferred_role_evidence = evidence
            column.role_detected_at = detected_at or datetime.now(timezone.utc)
            self.db.commit()

    def update_column_stats(
        self,
        dataset_id: str,
        column_name: str,
        *,
        detected_type: str,
        nullable: bool,
        unique_count: int,
        missing_percentage: float,
        missing_count: int | None = None,
    ) -> None:
        stmt = select(DatasetColumn).where(
            DatasetColumn.dataset_id == dataset_id,
            DatasetColumn.column_name == column_name,
        )
        column = self.db.execute(stmt).scalars().first()
        if column is not None:
            column.detected_type = detected_type
            column.nullable = nullable
            column.unique_count = unique_count
            if missing_count is not None:
                column.missing_count = int(missing_count)
            column.missing_percentage = missing_percentage
            self.db.flush()

    def get_columns_for_version(self, version_pk: str) -> list[DatasetColumn]:
        stmt = (
            select(DatasetColumn)
            .where(DatasetColumn.version_pk == version_pk)
            .order_by(DatasetColumn.id.asc())
        )
        return list(self.db.execute(stmt).scalars().all())

    def count_distinct_row_values(self, version_pk: str, column_name: str) -> int:
        expression = DatasetRow.row_data[column_name].as_string()
        stmt = select(func.count(func.distinct(expression))).where(
            DatasetRow.version_pk == version_pk
        )
        return int(self.db.execute(stmt).scalar_one() or 0)

    def count_distinct_physical_value(
        self,
        table_name: str,
        column_name: str,
        columns: list[tuple[str, str]],
    ) -> int:
        from .physical_table import build_physical_table

        table = build_physical_table(table_name, columns)
        stmt = select(func.count(func.distinct(table.c[column_name])))
        return int(self.db.execute(stmt).scalar_one() or 0)

    def get_by_id(self, dataset_id: str) -> Dataset | None:
        return self.db.get(Dataset, dataset_id)

    def find_by_file_hash(self, file_hash: str, organization_id: str) -> Dataset | None:
        stmt = select(Dataset).where(
            Dataset.file_hash == file_hash,
            Dataset.organization_id == organization_id,
        )
        return self.db.execute(stmt).scalars().first()

    def list_by_organization(self, organization_id: str, limit: int = 50) -> list[Dataset]:
        stmt = (
            select(Dataset)
            .where(
                Dataset.organization_id == organization_id,
                Dataset.status != "deleted",
            )
            .order_by(Dataset.created_at.desc())
            .limit(limit)
        )
        return list(self.db.execute(stmt).scalars().all())

    def get_columns(self, dataset_id: str) -> list[DatasetColumn]:
        stmt = select(DatasetColumn).where(DatasetColumn.dataset_id == dataset_id).order_by(DatasetColumn.id.asc())
        return list(self.db.execute(stmt).scalars().all())

    def get_version(self, dataset_id: str, version_id: str | None = None) -> DatasetVersion | None:
        if version_id is None:
            dataset = self.get_by_id(dataset_id)
            version_id = dataset.current_version_id if dataset else None
        if not version_id:
            return None
        stmt = select(DatasetVersion).where(
            DatasetVersion.dataset_id == dataset_id,
            DatasetVersion.version_id == version_id,
        )
        return self.db.execute(stmt).scalars().first()

    def list_versions(self, dataset_id: str) -> list[DatasetVersion]:
        stmt = (
            select(DatasetVersion)
            .where(DatasetVersion.dataset_id == dataset_id)
            .order_by(DatasetVersion.version_number.asc())
        )
        return list(self.db.execute(stmt).scalars().all())

    def get_rows(
        self,
        version_pk: str,
        *,
        limit: int = 1000,
        offset: int = 0,
    ):
        version = self.db.get(DatasetVersion, version_pk)
        if version is None or not version.data_table_name:
            return []
        columns = self.get_columns_for_version(version_pk)
        physical_columns = [(c.column_name, c.detected_type) for c in columns]
        from .physical_table import ROW_NUMBER_COLUMN, build_physical_table

        table = build_physical_table(version.data_table_name, physical_columns)
        stmt = (
            select(table)
            .order_by(table.c[ROW_NUMBER_COLUMN].asc())
            .offset(max(0, offset))
            .limit(min(max(1, limit), 10000))
        )
        return [
            {
                "row_number": row[ROW_NUMBER_COLUMN],
                "row_data": {name: row[name] for name, _ in physical_columns},
            }
            for row in self.db.execute(stmt).mappings()
        ]

    def count_rows(self, version_pk: str) -> int:
        version = self.db.get(DatasetVersion, version_pk)
        if version is not None and version.data_table_name:
            from .physical_table import ROW_NUMBER_COLUMN, build_physical_table
            columns = self.get_columns_for_version(version_pk)
            table = build_physical_table(
                version.data_table_name,
                [(c.column_name, c.detected_type) for c in columns],
            )
            return int(self.db.execute(select(func.count(table.c[ROW_NUMBER_COLUMN]))).scalar_one())
        return int(
            self.db.execute(
                select(func.count(DatasetRow.row_id)).where(DatasetRow.version_pk == version_pk)
            ).scalar_one()
        )

    def delete_dataset(self, dataset_id: str, *, commit: bool = True) -> None:
        dataset = self.get_by_id(dataset_id)
        if dataset is None:
            return
        self.db.delete(dataset)
        self.db.flush()
        if commit:
            self.db.commit()

    def delete_version_rows(self, version_pk: str, *, commit: bool = True) -> None:
        version = self.db.get(DatasetVersion, version_pk)
        if version is not None and version.data_table_name:
            from .physical_table import drop_physical_table
            drop_physical_table(self.db.connection(), version.data_table_name)
            version.data_table_name = None
        self.db.execute(delete(DatasetRow).where(DatasetRow.version_pk == version_pk))
        if commit:
            self.db.commit()

    def delete_version_columns(self, version_pk: str, *, commit: bool = True) -> None:
        self.db.execute(delete(DatasetColumn).where(DatasetColumn.version_pk == version_pk))
        if commit:
            self.db.commit()

    def list_all_for_organization_excluding(
        self, organization_id: str, exclude_dataset_id: str, limit: int = 25
    ) -> list[Dataset]:
        stmt = (
            select(Dataset)
            .where(
                Dataset.organization_id == organization_id,
                Dataset.dataset_id != exclude_dataset_id,
                Dataset.status.notin_({"deleted", "failed"}),
            )
            .order_by(Dataset.created_at.desc())
            .limit(limit)
        )
        return list(self.db.execute(stmt).scalars().all())
