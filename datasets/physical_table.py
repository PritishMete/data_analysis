from __future__ import annotations

import re
import unicodedata
from datetime import datetime
from decimal import Decimal
from typing import Any, Iterable

from sqlalchemy import BigInteger, Boolean, Column, DateTime, MetaData, Numeric, Table, Text, inspect, text
from sqlalchemy.engine import Connection

PHYSICAL_SCHEMA = "managed_data"
ROW_NUMBER_COLUMN = "__row_number"
_TABLE_RE = re.compile(r"^[a-z0-9_]+$")


def physical_table_name(version_pk: str) -> str:
    compact = re.sub(r"[^a-zA-Z0-9]", "", str(version_pk)).lower()
    return f"dataset_{compact}"


def _dataset_name_slug(dataset_name: str) -> str:
    normalized = unicodedata.normalize("NFKD", str(dataset_name or ""))
    ascii_name = normalized.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-zA-Z0-9]+", "_", ascii_name).strip("_").lower()
    return slug or "managed_dataset"


def resolve_dataset_table_name(
    connection: Connection,
    *,
    dataset_name: str,
    dataset_id: str,
    version_number: int,
    version_pk: str,
) -> str:
    """Resolve a readable, collision-safe table name for one dataset version.

    The first version uses the dataset's normalized name when it is available.
    Subsequent versions retain the same readable base and add a version suffix.
    Names are kept below PostgreSQL's 63-byte identifier limit and contain only
    lowercase ASCII letters, digits, and underscores.
    """
    schema = PHYSICAL_SCHEMA if connection.dialect.name == "postgresql" else None
    base = _dataset_name_slug(dataset_name)
    version_suffix = f"_v{int(version_number)}" if int(version_number) > 1 else ""

    # Serialize table-name resolution for identical human-readable names so
    # two concurrent uploads cannot both select the same physical table.
    if connection.dialect.name == "postgresql":
        lock_key = f"{schema}.{base}{version_suffix}"
        connection.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
            {"lock_key": lock_key},
        )

    def candidate(extra_suffix: str = "") -> str:
        suffix = f"{extra_suffix}{version_suffix}"
        stem_limit = max(1, 63 - len(suffix))
        return f"{base[:stem_limit].rstrip('_') or 'dataset'}{suffix}"

    def exists(table_name: str) -> bool:
        return inspect(connection).has_table(table_name, schema=schema)

    preferred = candidate()
    if not exists(preferred):
        return preferred

    dataset_suffix = "_" + re.sub(r"[^a-zA-Z0-9]", "", str(dataset_id)).lower()[-8:]
    disambiguated = candidate(dataset_suffix)
    if not exists(disambiguated):
        return disambiguated

    version_key = "_" + re.sub(r"[^a-zA-Z0-9]", "", str(version_pk)).lower()[-8:]
    final_name = candidate(dataset_suffix + version_key)
    if not exists(final_name):
        return final_name

    raise RuntimeError("Could not allocate a unique managed dataset table name.")


def _sql_type(detected_type: str):
    if detected_type == "integer":
        return BigInteger()
    if detected_type == "decimal":
        return Numeric()
    if detected_type == "boolean":
        return Boolean()
    if detected_type == "datetime":
        return DateTime(timezone=True)
    return Text()


def build_physical_table(
    table_name: str,
    columns: Iterable[tuple[str, str]],
    *,
    schema: str | None = PHYSICAL_SCHEMA,
) -> Table:
    if not _TABLE_RE.fullmatch(table_name):
        raise ValueError("Invalid managed dataset table name.")
    metadata = MetaData()
    sql_columns = [
        Column(ROW_NUMBER_COLUMN, BigInteger, primary_key=True, nullable=False)
    ]
    sql_columns.extend(
        Column(str(name), _sql_type(str(detected_type)), nullable=True)
        for name, detected_type in columns
    )
    return Table(table_name, metadata, *sql_columns, schema=schema)


def ensure_schema(connection: Connection) -> None:
    if connection.dialect.name == "postgresql":
        connection.execute(text("CREATE SCHEMA IF NOT EXISTS managed_data"))


def create_physical_table(
    connection: Connection,
    table_name: str,
    columns: Iterable[tuple[str, str]],
) -> Table:
    ensure_schema(connection)
    schema = PHYSICAL_SCHEMA if connection.dialect.name == "postgresql" else None
    table = build_physical_table(table_name, columns, schema=schema)
    table.create(connection, checkfirst=False)
    if schema:
        quoted = f'"{schema}"."{table_name}"'
        connection.execute(text(f"ALTER TABLE {quoted} ENABLE ROW LEVEL SECURITY"))
        connection.execute(text(f"REVOKE ALL ON TABLE {quoted} FROM anon, authenticated"))
    return table


def drop_physical_table(connection: Connection, table_name: str) -> None:
    if not _TABLE_RE.fullmatch(table_name):
        raise ValueError("Invalid managed dataset table name.")
    metadata = MetaData()
    table = Table(
        table_name,
        metadata,
        schema=PHYSICAL_SCHEMA if connection.dialect.name == "postgresql" else None,
    )
    table.drop(connection, checkfirst=True)


def coerce_value(value: Any, detected_type: str) -> Any:
    if value is None:
        return None
    if detected_type == "integer":
        return int(value)
    if detected_type == "decimal":
        return Decimal(str(value))
    if detected_type == "boolean":
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in {"true", "1", "yes"}
    if detected_type == "datetime":
        if isinstance(value, datetime):
            return value
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed
    return str(value)


def normalize_record(
    record: dict[str, Any],
    columns: list[tuple[str, str]],
    row_number: int,
) -> dict[str, Any]:
    payload: dict[str, Any] = {ROW_NUMBER_COLUMN: int(row_number)}
    for name, detected_type in columns:
        payload[name] = coerce_value(record.get(name), detected_type)
    return payload
