from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.db import get_db
from core.excel_handoff_store import cancel, claim, complete, create
from core.excel_handoff_diagnostics import event, new_correlation_id
from firebase_authz.supabase_auth import (
    AuthenticationRequired,
    SupabaseAuthUnavailable,
    verify_supabase_access_token,
)

router = APIRouter(prefix="/v1/excel-auth/handoff", tags=["excel-auth"])
Capability = Annotated[str, Field(min_length=43, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]


class HandoffRequest(BaseModel):
    transaction_id: UUID
    claim_capability: Capability
    completion_capability: Capability


class CompleteRequest(BaseModel):
    transaction_id: UUID
    completion_capability: Capability
    access_token: Annotated[str, Field(min_length=20, max_length=8192)]
    refresh_token: Annotated[str, Field(min_length=20, max_length=8192)]


class ClaimRequest(BaseModel):
    transaction_id: UUID
    claim_capability: Capability


class CancelRequest(ClaimRequest):
    pass


def _project_url() -> str:
    url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
    ref = os.getenv("SUPABASE_PROJECT_REF", "").strip()
    return url or (f"https://{ref}.supabase.co" if ref else "")


def _refresh_pair(refresh_token: str) -> tuple[str, str]:
    url = _project_url()
    key = (os.getenv("SUPABASE_PUBLISHABLE_KEY") or
           os.getenv("INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY") or "").strip()
    if not url or not key:
        raise RuntimeError("Supabase authentication is unavailable.")
    request = urllib.request.Request(
        f"{url}/auth/v1/token?grant_type=refresh_token",
        data=json.dumps({"refresh_token": refresh_token}).encode(),
        headers={"apikey": key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read())
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError,
            json.JSONDecodeError) as exc:
        raise AuthenticationRequired("Supabase session could not be refreshed.") from exc
    access = str(payload.get("access_token") or "")
    rotated = str(payload.get("refresh_token") or "")
    if not access or not rotated:
        raise AuthenticationRequired("Supabase session could not be refreshed.")
    return access, rotated


def _commit_or_fail(db: Session) -> None:
    try:
        db.commit()
    except Exception:
        db.rollback()
        raise


@router.post("/create", status_code=201)
def create_handoff(payload: HandoffRequest, db: Session = Depends(get_db)):
    if not create(db, payload.transaction_id, payload.claim_capability,
                  payload.completion_capability):
        raise HTTPException(status_code=409, detail="Authentication handoff unavailable.")
    _commit_or_fail(db)
    return {"transaction_id": str(payload.transaction_id), "expires_in": 180}


@router.post("/complete", status_code=204)
def complete_handoff(payload: CompleteRequest, db: Session = Depends(get_db)):
    correlation_id = new_correlation_id()
    event('handoff_complete_started', correlation_id=correlation_id, success=True)
    try:
        original = verify_supabase_access_token(payload.access_token)
        event('handoff_access_token_verified', correlation_id=correlation_id, success=True)
        try:
            refreshed_access, rotated_refresh = _refresh_pair(payload.refresh_token)
        except (AuthenticationRequired, RuntimeError, SupabaseAuthUnavailable) as exc:
            event(
                'handoff_supabase_refresh', correlation_id=correlation_id, success=False,
                exception_class=exc.__class__.__name__, category='provider_refresh_failure',
            )
            raise
        event('handoff_supabase_refresh', correlation_id=correlation_id, success=True)
        refreshed = verify_supabase_access_token(refreshed_access)
        same_identity = original.get('uid') == refreshed.get('uid')
        event(
            'handoff_refreshed_identity_verified',
            correlation_id=correlation_id,
            success=same_identity,
            category=None if same_identity else 'identity_mismatch',
        )
        if original.get("uid") != refreshed.get("uid"):
            raise AuthenticationRequired("Supabase session identity mismatch.")
        if not complete(db, payload.transaction_id, payload.completion_capability,
                        rotated_refresh):
            db.rollback()
            raise HTTPException(status_code=400, detail="Authentication handoff unavailable.")
        _commit_or_fail(db)
        event('handoff_persistence', correlation_id=correlation_id, success=True, status=204)
    except AuthenticationRequired as exc:
        event(
            'handoff_complete', correlation_id=correlation_id, success=False,
            status=401, exception_class=exc.__class__.__name__,
            category='authentication_failure',
        )
        db.rollback()
        raise HTTPException(status_code=401, detail="Authentication could not be verified.") from exc
    except (RuntimeError, SupabaseAuthUnavailable) as exc:
        event(
            'handoff_complete', correlation_id=correlation_id, success=False,
            status=503, exception_class=exc.__class__.__name__,
            category='provider_unavailable',
        )
        db.rollback()
        raise HTTPException(status_code=503, detail="Authentication is temporarily unavailable.") from exc


@router.post("/claim")
def claim_handoff(payload: ClaimRequest, db: Session = Depends(get_db)):
    token = claim(db, payload.transaction_id, payload.claim_capability)
    if token is None:
        db.rollback()
        raise HTTPException(status_code=404, detail="Authentication handoff unavailable.")
    _commit_or_fail(db)
    return {"refresh_token": token}


@router.post("/cancel", status_code=204)
def cancel_handoff(payload: CancelRequest, db: Session = Depends(get_db)):
    cancel(db, payload.transaction_id, payload.claim_capability)
    _commit_or_fail(db)
