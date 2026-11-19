from __future__ import annotations

import hashlib
import ipaddress
import secrets
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.db import get_db
from core import excel_handoff_store as store
from firebase_authz.supabase_auth import (
    AuthenticationRequired, SupabaseAuthUnavailable, verify_supabase_access_token,
)

router = APIRouter(prefix="/v2/excel-auth/handoff", tags=["excel-auth"])
Secret = Annotated[str, Field(min_length=40, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]
Token = Annotated[str, Field(min_length=20, max_length=8192)]
Pairing = Annotated[str, Field(min_length=19, max_length=19, pattern=r"^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$")]


def _secret() -> str:
    return secrets.token_urlsafe(32)


def _pairing() -> str:
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    raw = secrets.token_bytes(10)
    value = "".join(alphabet[(int.from_bytes(raw, "big") >> (75 - 5*i)) & 31] for i in range(16))
    return "-".join(value[i:i+4] for i in range(0, 16, 4))


def _ip_digest(request: Request) -> bytes:
    host = request.client.host if request.client else "unknown"
    try:
        normalized = str(ipaddress.ip_address(host))
    except ValueError:
        normalized = "unknown"
    return hashlib.sha256(normalized.encode()).digest()


def _commit(db: Session) -> None:
    try:
        db.commit()
    except Exception:
        db.rollback()
        raise


def _unavailable() -> HTTPException:
    return HTTPException(status_code=404, detail="Excel sign-in request is unavailable.")


class CreateRequest(BaseModel):
    excel_instance_id: Annotated[str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]


class BindRequest(BaseModel):
    transaction_id: UUID
    pairing_code: Pairing
    browser_capability: Secret
    request_id: UUID


class CandidateRequest(BaseModel):
    transaction_id: UUID
    browser_capability: Secret
    generation: Annotated[int, Field(ge=1)]
    request_id: UUID
    access_token: Token



class BrowserStatusRequest(BaseModel):
    transaction_id: UUID
    browser_capability: Secret


class StatusRequest(BaseModel):
    transaction_id: UUID
    status_capability: Secret


class ApproveRequest(BaseModel):
    transaction_id: UUID
    approval_capability: Secret
    candidate_uid: UUID
    generation: Annotated[int, Field(ge=1)]
    decision: str = Field(pattern="^(approve|reject)$")
    request_id: UUID


class CompleteRequest(BaseModel):
    transaction_id: UUID
    browser_capability: Secret
    generation: Annotated[int, Field(ge=1)]
    request_id: UUID
    access_token: Token
    refresh_token: Token


class ClaimRequest(BaseModel):
    transaction_id: UUID
    claim_capability: Secret


class CancelRequest(BaseModel):
    transaction_id: UUID
    cancel_capability: Secret


class RetryRequest(BaseModel):
    transaction_id: UUID
    retry_capability: Secret
    generation: Annotated[int, Field(ge=1)]
    request_id: UUID


@router.post("/create", status_code=201)
def create_handoff(
    payload: CreateRequest,
    request: Request,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=16, max_length=128)],
    response: Response,
    db: Session = Depends(get_db),
):
    transaction = uuid4()
    values = {key: _secret() for key in ("claim", "completion", "status", "approval", "cancel", "retry")}
    pairing = _pairing()
    try:
        created = store.create(db, transaction, values, pairing, payload.excel_instance_id, _ip_digest(request), idempotency_key)
        if created == "duplicate":
            db.rollback()
            raise HTTPException(status_code=409, detail="create_outcome_unknown: start a new Excel sign-in request.")
        if not created:
            db.rollback()
            raise HTTPException(status_code=429, detail="Too many Excel sign-in attempts. Try again later.")
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Pragma"] = "no-cache"
    return {
        "transaction_id": str(transaction), "generation": 1, "expires_in": 600,
        "pairing_code": pairing, "claim_capability": values["claim"],
        "status_capability": values["status"],
        "approval_capability": values["approval"], "cancel_capability": values["cancel"],
        "retry_capability": values["retry"],
    }


@router.post("/browser/bind")
def bind(payload: BindRequest, db: Session = Depends(get_db)):
    try:
        generation = store.bind_browser(db, payload.transaction_id, payload.pairing_code,
                                        payload.browser_capability, payload.request_id)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if generation is None:
        raise _unavailable()
    return {"state": "browser_bound", "generation": generation}


@router.post("/browser/candidate")
def candidate(payload: CandidateRequest, db: Session = Depends(get_db)):
    try:
        identity = verify_supabase_access_token(payload.access_token)
        uid = str(identity.get("uid") or "")
        email = str(identity.get("email") or "")
        if not uid:
            raise AuthenticationRequired("Supabase identity is invalid.")
        ok = store.candidate(db, payload.transaction_id, payload.browser_capability,
                             payload.generation, payload.request_id, uid, email)
        _commit(db)
    except AuthenticationRequired as exc:
        db.rollback()
        raise HTTPException(status_code=401, detail="The signed-in account could not be verified.") from exc
    except SupabaseAuthUnavailable as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Account verification is temporarily unavailable.") from exc
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if not ok:
        raise _unavailable()
    return {"state": "candidate_pending_approval", "generation": payload.generation}



@router.post("/browser/status")
def browser_status(payload: BrowserStatusRequest, db: Session = Depends(get_db)):
    try:
        result = store.browser_status(db, payload.transaction_id, payload.browser_capability)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if result is None:
        raise _unavailable()
    return result


@router.post("/status")
def get_status(payload: StatusRequest, db: Session = Depends(get_db)):
    try:
        result = store.status(db, payload.transaction_id, payload.status_capability)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if result is None:
        raise _unavailable()
    result["candidate_uid"] = str(result["candidate_uid"]) if result["candidate_uid"] else None
    result["approved_uid"] = str(result["approved_uid"]) if result["approved_uid"] else None
    result["expires_at"] = result["expires_at"].isoformat()
    return result


@router.post("/approve")
def approve(payload: ApproveRequest, db: Session = Depends(get_db)):
    try:
        ok = store.approve(db, payload.transaction_id, payload.approval_capability,
                           str(payload.candidate_uid), payload.generation,
                           payload.decision, payload.request_id)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if not ok:
        raise _unavailable()
    return {"state": "approved" if payload.decision == "approve" else "rejected",
            "generation": payload.generation}


@router.post("/browser/complete")
def complete(payload: CompleteRequest, db: Session = Depends(get_db)):
    try:
        identity = verify_supabase_access_token(payload.access_token)
        uid = str(identity.get("uid") or "")
        if not uid:
            raise AuthenticationRequired("Supabase identity is invalid.")
        ok = store.complete(db, payload.transaction_id, payload.browser_capability,
                            payload.generation, payload.request_id, uid, payload.refresh_token)
        _commit(db)
    except AuthenticationRequired as exc:
        db.rollback()
        raise HTTPException(status_code=401, detail="The signed-in account could not be verified.") from exc
    except SupabaseAuthUnavailable as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Account verification is temporarily unavailable.") from exc
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if not ok:
        raise _unavailable()
    return {"state": "completed", "generation": payload.generation}


@router.post("/claim")
def claim(payload: ClaimRequest, response: Response, db: Session = Depends(get_db)):
    try:
        token = store.claim(db, payload.transaction_id, payload.claim_capability)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if token is None:
        raise _unavailable()
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Pragma"] = "no-cache"
    return {"refresh_token": token}


@router.post("/cancel")
def cancel(payload: CancelRequest, db: Session = Depends(get_db)):
    try:
        cancelled = store.cancel(db, payload.transaction_id, payload.cancel_capability)
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if not cancelled:
        raise _unavailable()
    return {"state": "cancelled"}


@router.post("/retry")
def retry(payload: RetryRequest, response: Response, db: Session = Depends(get_db)):
    pairing = _pairing()
    try:
        generation = store.retry(
            db, payload.transaction_id, payload.retry_capability,
            pairing, payload.request_id, payload.generation,
        )
        _commit(db)
    except RuntimeError as exc:
        db.rollback()
        raise HTTPException(status_code=503, detail="Excel sign-in is temporarily unavailable.") from exc
    if generation is None:
        raise _unavailable()
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["Pragma"] = "no-cache"
    return {"pairing_code": pairing, "generation": generation}
