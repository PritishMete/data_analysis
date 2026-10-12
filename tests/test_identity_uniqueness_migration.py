from __future__ import annotations

import os
import re
import uuid
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.exc import DBAPIError, IntegrityError

DATABASE_URL = os.environ.get("IDENTITY_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(
    not DATABASE_URL,
    reason="IDENTITY_TEST_DATABASE_URL must point to a disposable PostgreSQL database",
)


def _migration_parts() -> tuple[str, list[str]]:
    sql = Path("migrations/0026_member_identity_uniqueness.sql").read_text(
        encoding="utf-8"
    )
    start = sql.index("DO $$")
    end = sql.index("$$;", start) + len("$$;")
    preflight = sql[start:end]
    indexes = re.findall(
        r"CREATE UNIQUE INDEX IF NOT EXISTS .*?;",
        sql,
        flags=re.DOTALL,
    )
    assert len(indexes) == 2
    return preflight, indexes


def _database():
    engine = create_engine(DATABASE_URL)
    connection = engine.connect()
    schema = "identity_test_" + uuid.uuid4().hex
    connection.exec_driver_sql(f'CREATE SCHEMA "{schema}"')
    connection.commit()
    connection.exec_driver_sql(f'SET search_path TO "{schema}"')
    connection.exec_driver_sql(
        """
        CREATE TABLE organization_member_profiles (
            organization_id text NOT NULL,
            principal_id text NOT NULL,
            phone_e164 text,
            id_proof_type text,
            id_proof_number text
        )
        """
    )
    connection.commit()
    return engine, connection, schema


def _apply_migration(connection) -> None:
    preflight, indexes = _migration_parts()
    connection.exec_driver_sql(preflight)
    for statement in indexes:
        connection.exec_driver_sql(statement)


def _cleanup(engine, connection, schema: str) -> None:
    connection.rollback()
    connection.exec_driver_sql(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
    connection.commit()
    connection.close()
    engine.dispose()


def test_identity_migration_enforces_phone_and_normalized_id_uniqueness():
    engine, connection, schema = _database()
    try:
        with connection.begin():
            _apply_migration(connection)

        with connection.begin():
            connection.execute(
                text(
                    """
                    INSERT INTO organization_member_profiles
                      (organization_id, principal_id, phone_e164,
                       id_proof_type, id_proof_number)
                    VALUES ('org-a', 'principal-a', '+14155552671',
                            'passport', 'AB-123 45')
                    """
                )
            )

        with pytest.raises(IntegrityError):
            with connection.begin():
                connection.execute(
                    text(
                        """
                        INSERT INTO organization_member_profiles
                          (organization_id, principal_id, phone_e164)
                        VALUES ('org-b', 'principal-b', '+14155552671')
                        """
                    )
                )

        with pytest.raises(IntegrityError):
            with connection.begin():
                connection.execute(
                    text(
                        """
                        INSERT INTO organization_member_profiles
                          (organization_id, principal_id, id_proof_type, id_proof_number)
                        VALUES ('org-c', 'principal-c', 'passport', 'ab12345')
                        """
                    )
                )
    finally:
        _cleanup(engine, connection, schema)


def test_identity_migration_preflight_aborts_on_existing_duplicate_values():
    engine, connection, schema = _database()
    try:
        with connection.begin():
            connection.execute(
                text(
                    """
                    INSERT INTO organization_member_profiles
                      (organization_id, principal_id, phone_e164)
                    VALUES ('org-a', 'principal-a', '+14155552671'),
                           ('org-b', 'principal-b', '+14155552671')
                    """
                )
            )

        preflight, _ = _migration_parts()
        with pytest.raises(DBAPIError, match="Identity uniqueness migration blocked"):
            with connection.begin():
                connection.exec_driver_sql(preflight)
    finally:
        _cleanup(engine, connection, schema)
