"""Caller owns the PostgreSQL transaction; commit a claim before sending its result."""

import hashlib
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.orm import Session

from core.excel_handoff_crypto import seal_refresh_token, unseal_refresh_token


def _digest(capability: str) -> bytes:
    return hashlib.sha256(capability.encode("ascii")).digest()


def create(db: Session, transaction: UUID, claim: str, completion: str) -> bool:
    result = db.execute(text("""
        INSERT INTO excel_handoff.transactions (id, claim_digest, completion_digest)
        VALUES (:id, :claim, :completion) ON CONFLICT (id) DO NOTHING
        RETURNING id
    """), {"id": transaction, "claim": _digest(claim), "completion": _digest(completion)})
    return result.scalar_one_or_none() is not None


def complete(db: Session, transaction: UUID, capability: str, verified_refresh_token: str) -> bool:
    result = db.execute(text("""
        UPDATE excel_handoff.transactions
        SET ciphertext = :sealed, status = 'completed'
        WHERE id = :id AND completion_digest = :digest AND ciphertext IS NULL
          AND status = 'pending'
          AND expires_at > clock_timestamp() RETURNING id
    """), {"sealed": seal_refresh_token(transaction, verified_refresh_token),
           "id": transaction, "digest": _digest(capability)})
    return result.scalar_one_or_none() is not None


def claim(db: Session, transaction: UUID, capability: str) -> str | None:
    sealed = db.execute(text("""
        WITH claimed AS (
            SELECT id, ciphertext FROM excel_handoff.transactions
            WHERE id = :id AND claim_digest = :digest AND ciphertext IS NOT NULL
              AND status = 'completed' AND expires_at > clock_timestamp()
            FOR UPDATE SKIP LOCKED
        )
        UPDATE excel_handoff.transactions AS t
        SET status = 'claimed', ciphertext = NULL
        FROM claimed
        WHERE t.id = claimed.id
        RETURNING claimed.ciphertext
    """), {"id": transaction, "digest": _digest(capability)}).scalar_one_or_none()
    return None if sealed is None else unseal_refresh_token(transaction, bytes(sealed))


def cancel(db: Session, transaction: UUID, capability: str) -> None:
    db.execute(text("""
        UPDATE excel_handoff.transactions SET status = 'cancelled', ciphertext = NULL
        WHERE id = :id AND claim_digest = :digest
    """), {"id": transaction, "digest": _digest(capability)})


def cleanup(db: Session) -> None:
    db.execute(text("DELETE FROM excel_handoff.transactions WHERE expires_at <= clock_timestamp()"))
