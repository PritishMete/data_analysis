from __future__ import annotations

import re
from datetime import datetime
from decimal import Decimal
from typing import Any, Iterable

from sqlalchemy import BigInteger, Boolean, Column, DateTime, MetaData, Numeric, Table, Text, text
from sqlalchemy.engine import Connection

PHYSICAL_SCHEMA = "managed_data"
ROW_NUMBER_COLUMN = "__row_number"
_TABLE_RE = re.compile(r"^[a-z0-9_]+$")


def physical_table_name(version_pk: str) -> str:
    compact = re.sub(r"[^a-zA-Z0-9]", "", str(version_pk)).lower()
    return f"dataset_{compact}"


def _sql_type(detected_type: str):
    if detected_type == "integer":
        return BigInteger()
    if detected_type == "decimal":
        return Numeric(38, 10)
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
    table.create(connection, checkfirst=True)
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
