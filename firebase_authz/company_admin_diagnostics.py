"""Company-wide internal support diagnostics, isolated from tenant-scoped admin roles."""
from __future__ import annotations

import json
import uuid
from fastapi import APIRouter, Header, HTTPException, Query
from sqlalchemy import text

from core.db import SessionLocal
from .admin_diagnostics import _claims, _paging

router = APIRouter(prefix="/v1/company-admin", tags=["company-admin-diagnostics"])


def _company_actor(authorization: str | None) -> dict:
    claims = _claims(authorization)
    subject = str(claims.get("sub") or claims.get("uid") or "").strip()
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT p.principal_id
            FROM identity_bindings ib
            JOIN principals p ON p.principal_id=ib.principal_id
            JOIN insightflow_company_admins ca ON ca.principal_id=p.principal_id
            WHERE ib.provider='supabase' AND ib.provider_subject=:subject
              AND ca.active=true
        """), {"subject": subject}).mappings().first()
    if not row:
        raise HTTPException(403, "InsightFlow company administrator access denied.")
    return {"principal_id": row["principal_id"], "subject": subject}


def _audit(actor: dict, action: str, metadata: dict | None = None) -> None:
    with SessionLocal.begin() as db:
        db.execute(text("""
            INSERT INTO insightflow_company_admin_audit
              (audit_id, actor_principal_id, action, metadata)
            VALUES (:id, :actor, :action, CAST(:metadata AS jsonb))
        """), {"id": "caudit_" + uuid.uuid4().hex, "actor": actor["principal_id"],
               "action": action, "metadata": json.dumps(metadata or {})})


@router.get("/overview")
def company_overview(authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT count(*) AS total_events,
                   count(DISTINCT user_principal_id) AS users,
                   count(DISTINCT organization_id) AS organizations,
                   count(*) FILTER (WHERE status IN ('failed','error')) AS failures,
                   max(event_at) AS latest_event
            FROM diagnostic_events
        """)).mappings().one()
    _audit(actor, "company_diagnostics.overview.viewed")
    return dict(row)


@router.get("/users")
def company_users(q: str = Query(default="", max_length=160),
                  page: int = Query(1, ge=1),
                  page_size: int = Query(50, ge=1, le=100),
                  authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT e.user_principal_id AS principal_id,
                   ib.provider_subject AS user_id, au.email,
                   count(*) AS event_count,
                   count(*) FILTER (WHERE e.status IN ('failed','error')) AS failures,
                   max(e.event_at) AS last_seen,
                   count(DISTINCT e.organization_id) AS organization_count
            FROM diagnostic_events e
            JOIN principals p ON p.principal_id=e.user_principal_id
            LEFT JOIN identity_bindings ib ON ib.principal_id=p.principal_id AND ib.provider='supabase'
            LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
            WHERE e.user_principal_id IS NOT NULL
              AND (:q = '' OR ib.provider_subject ILIKE :pattern OR au.email ILIKE :pattern)
            GROUP BY e.user_principal_id, ib.provider_subject, au.email
            ORDER BY max(e.event_at) DESC
            OFFSET :offset LIMIT :limit
        """), {"q": q.strip(), "pattern": f"%{q.strip()}%", "offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.directory.searched")
    return {"users": [dict(row) for row in rows], "page": page, "page_size": page_size}


@router.get("/users/{principal_id}/timeline")
def company_user_timeline(principal_id: str, page: int = Query(1, ge=1),
                          page_size: int = Query(50, ge=1, le=100),
                          authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT e.event_id, e.event_at, e.organization_id, o.name AS organization_name,
                   e.branch_id, e.correlation_id, e.category, e.status,
                   e.sanitized_error, e.payload
            FROM diagnostic_events e
            LEFT JOIN organizations o ON o.organization_id=e.organization_id
            WHERE e.user_principal_id=:principal
            ORDER BY e.event_at DESC OFFSET :offset LIMIT :limit
        """), {"principal": principal_id, "offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.user_timeline.viewed")
    return {"events": [dict(row) for row in rows], "page": page, "page_size": page_size}


@router.get("/events/search")
def company_event_search(q: str = Query(..., min_length=2, max_length=160),
                         page: int = Query(1, ge=1),
                         page_size: int = Query(50, ge=1, le=100),
                         authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT e.event_id, e.event_at, e.organization_id, o.name AS organization_name,
                   e.user_principal_id, au.email, e.branch_id, e.correlation_id,
                   e.category, e.status, e.sanitized_error
            FROM diagnostic_events e
            LEFT JOIN organizations o ON o.organization_id=e.organization_id
            LEFT JOIN principals p ON p.principal_id=e.user_principal_id
            LEFT JOIN identity_bindings ib ON ib.principal_id=p.principal_id AND ib.provider='supabase'
            LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
            WHERE e.session_id ILIKE :pattern OR e.correlation_id ILIKE :pattern
               OR e.category ILIKE :pattern OR e.sanitized_error ILIKE :pattern
               OR au.email ILIKE :pattern
            ORDER BY e.event_at DESC OFFSET :offset LIMIT :limit
        """), {"pattern": f"%{q.strip()}%", "offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.events.searched")
    return {"events": [dict(row) for row in rows], "page": page, "page_size": page_size}


@router.get("/audit")
def company_audit(page: int = Query(1, ge=1), page_size: int = Query(50, ge=1, le=100),
                  authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT audit_id, action, metadata, created_at
            FROM insightflow_company_admin_audit
            ORDER BY created_at DESC OFFSET :offset LIMIT :limit
        """), {"offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.audit.viewed")
    return {"audit": [dict(row) for row in rows], "page": page, "page_size": page_size}
