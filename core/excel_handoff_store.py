"""PostgreSQL-only v2 Excel handoff state transitions.

The caller owns and commits each request transaction. A claim is committed
before its response is sent; a lost response must never be replayed.
"""
from __future__ import annotations

import hashlib
import hmac
import os
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.orm import Session

from core.excel_handoff_crypto import seal_refresh_token, unseal_refresh_token


def digest(value: str) -> bytes:
    return hashlib.sha256(value.encode("utf-8")).digest()


def pairing_digest(value: str) -> bytes:
    pepper = os.environ.get("INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY", "").encode()
    if len(pepper) < 32:
        raise RuntimeError("Excel handoff pairing protection is unavailable.")
    normalized = "".join(value.upper().split()).replace("-", "")
    return hmac.new(pepper, normalized.encode("ascii"), hashlib.sha256).digest()


def require_postgres(db: Session) -> None:
    if db.get_bind().dialect.name != "postgresql":
        raise RuntimeError("Excel v2 handoff requires PostgreSQL row locking.")


def create(db: Session, transaction: UUID, secrets: dict[str, str],
           pairing_code: str, excel_instance: str, ip_digest: bytes,
           idempotency_key: str | None = None) -> bool | str:
    require_postgres(db)
    cleanup(db)
    # Serialize rate-limit accounting per hashed source IP. The digest is never
    # reversible to an address and the transaction lock closes concurrent bursts.
    lock_key = int.from_bytes(ip_digest[:8], "big", signed=True)
    db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_key})
    key_digest = digest(idempotency_key) if idempotency_key else None
    if key_digest is not None:
        exists = db.execute(text("""
          SELECT 1 FROM excel_handoff.transactions
          WHERE protocol_version=2 AND create_idempotency_digest=:key
        """), {"key": key_digest}).scalar_one_or_none()
        if exists:
            return "duplicate"
    db.execute(text("""
      DELETE FROM excel_handoff.create_rate_limits
      WHERE created_at < clock_timestamp() - interval '1 hour'
    """))
    count = db.execute(text("""
      SELECT count(*) FROM excel_handoff.create_rate_limits
      WHERE ip_digest=:ip AND created_at > clock_timestamp()-interval '1 hour'
    """), {"ip": ip_digest}).scalar_one()
    if count >= 10:
        return False
    db.execute(text("INSERT INTO excel_handoff.create_rate_limits(ip_digest) VALUES (:ip)"),
               {"ip": ip_digest})
    inserted = db.execute(text("""
      INSERT INTO excel_handoff.transactions
       (id, protocol_version, status, claim_digest, completion_digest,
        status_capability_digest, approval_capability_digest,
        cancel_capability_digest, retry_capability_digest,
        pairing_digest, pairing_expires_at, excel_instance_digest,
        create_idempotency_digest, expires_at, last_activity_at)
      VALUES (:id, 2, 'pending', :claim, :completion, :status, :approval,
        :cancel, :retry, :pairing, clock_timestamp()+interval '3 minutes',
        :instance, :idempotency, clock_timestamp()+interval '10 minutes', clock_timestamp())
      ON CONFLICT DO NOTHING
      RETURNING id
    """), {
      "id": transaction, "claim": digest(secrets["claim"]),
      "completion": digest(secrets["completion"]),
      "status": digest(secrets["status"]), "approval": digest(secrets["approval"]),
      "cancel": digest(secrets["cancel"]), "retry": digest(secrets["retry"]),
      "pairing": pairing_digest(pairing_code), "instance": digest(excel_instance),
      "idempotency": key_digest,
    }).scalar_one_or_none()
    if inserted is None:
        return "duplicate"
    return True


def bind_browser(db: Session, transaction: UUID, pairing_code: str,
                 browser_capability: str, request_id: UUID) -> int | None:
    require_postgres(db)
    existing = db.execute(text("""
      SELECT generation FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND status='browser_bound'
        AND bind_request_id=:request AND browser_capability_digest=:browser
      FOR UPDATE
    """), {"id": transaction, "request": request_id,
           "browser": digest(browser_capability)}).scalar_one_or_none()
    if existing is not None:
        return int(existing)
    result = db.execute(text("""
      UPDATE excel_handoff.transactions
      SET status='browser_bound', browser_capability_digest=:browser,
          pairing_digest=NULL, pairing_expires_at=NULL, bind_request_id=:request,
          last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2 AND status='pending'
        AND expires_at>clock_timestamp() AND pairing_expires_at>clock_timestamp()
        AND pairing_attempts<5 AND pairing_digest=:pairing
      RETURNING generation
    """), {"browser": digest(browser_capability), "request": request_id,
           "id": transaction, "pairing": pairing_digest(pairing_code)})
    generation = result.scalar_one_or_none()
    if generation is not None:
        return int(generation)
    db.execute(text("""
      UPDATE excel_handoff.transactions SET pairing_attempts=pairing_attempts+1,
        last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2 AND status='pending'
        AND expires_at>clock_timestamp() AND pairing_attempts<5
    """), {"id": transaction})
    return None


def candidate(db: Session, transaction: UUID, browser: str, generation: int,
              request_id: UUID, uid: str, email: str) -> bool:
    require_postgres(db)
    existing = db.execute(text("""
      SELECT candidate_uid, candidate_generation FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND status='candidate_pending_approval'
        AND candidate_request_id=:request AND browser_capability_digest=:browser
      FOR UPDATE
    """), {"id": transaction, "request": request_id, "browser": digest(browser)}).one_or_none()
    if existing is not None:
        return str(existing.candidate_uid) == uid and existing.candidate_generation == generation
    result = db.execute(text("""
      UPDATE excel_handoff.transactions
      SET status='candidate_pending_approval', candidate_uid=:uid,
          candidate_email=:email, candidate_generation=:generation,
          candidate_request_id=:request, last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2 AND status='browser_bound'
        AND generation=:generation AND browser_capability_digest=:browser
        AND expires_at>clock_timestamp() AND candidate_uid IS NULL
      RETURNING id
    """), {"id": transaction, "browser": digest(browser), "generation": generation,
           "request": request_id, "uid": uid, "email": email})
    return result.scalar_one_or_none() is not None


def status(db: Session, transaction: UUID, capability: str) -> dict | None:
    require_postgres(db)
    cap = digest(capability)
    db.execute(text("""
      UPDATE excel_handoff.transactions SET status='expired', ciphertext=NULL,
        pairing_digest=NULL, browser_capability_digest=NULL
      WHERE id=:id AND protocol_version=2 AND status_capability_digest=:cap
        AND expires_at<=clock_timestamp()
        AND status IN ('pending','browser_bound','candidate_pending_approval','approved','completed')
    """), {"id": transaction, "cap": cap})
    row = db.execute(text("""
      SELECT status, generation, candidate_uid, candidate_email,
        candidate_generation, approved_uid, approved_generation, expires_at
      FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND status_capability_digest=:cap
    """), {"id": transaction, "cap": cap}).mappings().one_or_none()
    return None if row is None else dict(row)


def browser_status(db: Session, transaction: UUID, browser: str) -> dict | None:
    require_postgres(db)
    cap = digest(browser)
    db.execute(text("""
      UPDATE excel_handoff.transactions SET status='expired', ciphertext=NULL,
        pairing_digest=NULL, browser_capability_digest=NULL
      WHERE id=:id AND protocol_version=2 AND browser_capability_digest=:cap
        AND expires_at<=clock_timestamp()
        AND status IN ('pending','browser_bound','candidate_pending_approval','approved','completed')
    """), {"id": transaction, "cap": cap})
    row = db.execute(text("""
      SELECT status, generation, candidate_uid, candidate_email,
             candidate_generation, approved_uid, approved_generation
      FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND browser_capability_digest=:browser
    """), {"id": transaction, "browser": cap}).mappings().one_or_none()
    if row is None:
        # Completion clears the browser capability; the browser does not need
        # a post-completion poll because browser/complete returns success.
        return None
    return {
      "state": row["status"], "generation": row["generation"],
      "candidate_uid": str(row["candidate_uid"]) if row["candidate_uid"] else None,
      "candidate_email": row["candidate_email"],
      "candidate_generation": row["candidate_generation"],
      "approved_uid": str(row["approved_uid"]) if row["approved_uid"] else None,
      "approved_generation": row["approved_generation"],
    }


def approve(db: Session, transaction: UUID, capability: str, uid: str,
            generation: int, decision: str, request_id: UUID) -> bool:
    require_postgres(db)
    existing = db.execute(text("""
      SELECT status, approval_request_id, candidate_uid, candidate_generation
      FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND approval_capability_digest=:cap
      FOR UPDATE
    """), {"id": transaction, "cap": digest(capability)}).mappings().one_or_none()
    if existing and existing["approval_request_id"] == request_id:
        expected = "approved" if decision == "approve" else "rejected"
        return (existing["status"] == expected and str(existing["candidate_uid"]) == uid
                and existing["candidate_generation"] == generation)
    if decision == "reject":
        assignments = "status='rejected', ciphertext=NULL, pairing_digest=NULL, browser_capability_digest=NULL"
    else:
        assignments = "status='approved', approved_uid=:uid, approved_generation=:generation"
    result = db.execute(text(f"""
      UPDATE excel_handoff.transactions SET {assignments},
        approval_request_id=:request, last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2
        AND approval_capability_digest=:cap
        AND status='candidate_pending_approval'
        AND candidate_uid=:uid AND candidate_generation=:generation
        AND generation=:generation AND expires_at>clock_timestamp()
      RETURNING id
    """), {"id": transaction, "cap": digest(capability), "uid": uid,
           "generation": generation, "request": request_id})
    return result.scalar_one_or_none() is not None


def complete(db: Session, transaction: UUID, browser: str, generation: int,
             request_id: UUID, uid: str, refresh_token: str) -> bool:
    require_postgres(db)
    existing = db.execute(text("""
      SELECT status, completion_request_id, approved_uid, approved_generation
      FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND approved_uid=:uid
      FOR UPDATE
    """), {"id": transaction, "uid": uid}).mappings().one_or_none()
    if existing and existing["status"] == "completed" and existing["completion_request_id"] == request_id:
        return existing["approved_generation"] == generation
    sealed = seal_refresh_token(transaction, refresh_token, "refresh")
    result = db.execute(text("""
      UPDATE excel_handoff.transactions
      SET ciphertext=:sealed, status='completed', completed_at=clock_timestamp(),
        completion_request_id=:request, last_activity_at=clock_timestamp(),
        browser_capability_digest=NULL, pairing_digest=NULL
      WHERE id=:id AND protocol_version=2 AND status='approved'
        AND browser_capability_digest=:browser AND generation=:generation
        AND approved_uid=:uid AND approved_generation=:generation
        AND expires_at>clock_timestamp() AND ciphertext IS NULL
      RETURNING id
    """), {"sealed": sealed, "request": request_id, "id": transaction,
           "browser": digest(browser), "generation": generation, "uid": uid})
    return result.scalar_one_or_none() is not None


def claim(db: Session, transaction: UUID, capability: str) -> str | None:
    require_postgres(db)
    row = db.execute(text("""
      SELECT ciphertext FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND status='completed'
        AND claim_digest=:cap AND expires_at>clock_timestamp()
      FOR UPDATE
    """), {"id": transaction, "cap": digest(capability)}).mappings().one_or_none()
    if row is None or row["ciphertext"] is None:
        return None
    token = unseal_refresh_token(transaction, bytes(row["ciphertext"]), "refresh")
    updated = db.execute(text("""
      UPDATE excel_handoff.transactions SET status='claimed', ciphertext=NULL,
        claimed_at=clock_timestamp(), last_activity_at=clock_timestamp()
      WHERE id=:id AND status='completed' RETURNING id
    """), {"id": transaction}).scalar_one_or_none()
    return token if updated else None


def cancel(db: Session, transaction: UUID, capability: str) -> bool:
    require_postgres(db)
    existing = db.execute(text("""
      SELECT status FROM excel_handoff.transactions
      WHERE id=:id AND protocol_version=2 AND cancel_capability_digest=:cap
      FOR UPDATE
    """), {"id": transaction, "cap": digest(capability)}).scalar_one_or_none()
    if existing == "cancelled":
        return True
    if existing is None:
        return False
    result = db.execute(text("""
      UPDATE excel_handoff.transactions SET status='cancelled',
        cancelled_at=clock_timestamp(), ciphertext=NULL, pairing_digest=NULL,
        browser_capability_digest=NULL, last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2 AND cancel_capability_digest=:cap
        AND status IN ('pending','browser_bound','candidate_pending_approval','approved','completed')
      RETURNING id
    """), {"id": transaction, "cap": digest(capability)})
    return result.scalar_one_or_none() is not None


def retry(db: Session, transaction: UUID, capability: str, pairing_code: str,
          request_id: UUID) -> bool:
    require_postgres(db)
    result = db.execute(text("""
      UPDATE excel_handoff.transactions SET generation=generation+1,
        status='pending', pairing_digest=:pairing,
        pairing_expires_at=clock_timestamp()+interval '3 minutes',
        pairing_attempts=0, browser_capability_digest=NULL,
        candidate_uid=NULL, candidate_email=NULL, candidate_generation=NULL,
        approved_uid=NULL, approved_generation=NULL, candidate_request_id=NULL,
        bind_request_id=NULL, approval_request_id=NULL, completion_request_id=NULL,
        retry_request_id=:request, ciphertext=NULL, completed_at=NULL,
        last_activity_at=clock_timestamp()
      WHERE id=:id AND protocol_version=2 AND retry_capability_digest=:cap
        AND status IN ('pending','browser_bound') AND candidate_uid IS NULL
        AND expires_at>clock_timestamp()
      RETURNING id
    """), {"id": transaction, "cap": digest(capability),
           "pairing": pairing_digest(pairing_code), "request": request_id,
           "expected_generation": expected_generation})
    return result.scalar_one_or_none() is not None


def cleanup(db: Session) -> None:
    require_postgres(db)
    db.execute(text("""
      UPDATE excel_handoff.transactions SET status='expired',
        pairing_digest=NULL, browser_capability_digest=NULL, ciphertext=NULL
      WHERE protocol_version=2 AND expires_at<=clock_timestamp()
        AND status IN ('pending','browser_bound','candidate_pending_approval','approved','completed')
    """))
