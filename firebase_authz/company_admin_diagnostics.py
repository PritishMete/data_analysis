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
            SELECT
              (SELECT count(*) FROM diagnostic_events) AS total_events,
              (SELECT count(DISTINCT principal_id) FROM organization_members WHERE status='active') AS users,
              (SELECT count(*) FROM organizations) AS organizations,
              (SELECT count(*) FROM diagnostic_events WHERE status IN ('failed','error')) AS failures,
              (SELECT max(event_at) FROM diagnostic_events) AS latest_event,
              (SELECT count(*) FROM organizations WHERE status='active') AS active_organizations
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
            WITH member_directory AS (
              SELECT om.principal_id,
                     count(DISTINCT om.organization_id) AS organization_count,
                     string_agg(DISTINCT o.name, ', ' ORDER BY o.name) AS organizations
              FROM organization_members om
              JOIN organizations o ON o.organization_id=om.organization_id
              WHERE om.status='active'
              GROUP BY om.principal_id
            ), event_rollup AS (
              SELECT user_principal_id,
                     count(*) AS event_count,
                     count(*) FILTER (WHERE status IN ('failed','error')) AS failures,
                     max(event_at) AS last_seen
              FROM diagnostic_events
              WHERE user_principal_id IS NOT NULL
              GROUP BY user_principal_id
            )
            SELECT p.principal_id, ib.provider_subject AS user_id, au.email,
                   coalesce(md.organization_count, 0) AS organization_count,
                   coalesce(md.organizations, '') AS organizations,
                   coalesce(er.event_count, 0) AS event_count,
                   coalesce(er.failures, 0) AS failures,
                   er.last_seen
            FROM principals p
            JOIN identity_bindings ib ON ib.principal_id=p.principal_id
              AND ib.provider='supabase' AND ib.status='active'
            LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
            LEFT JOIN member_directory md ON md.principal_id=p.principal_id
            LEFT JOIN event_rollup er ON er.user_principal_id=p.principal_id
            WHERE (md.principal_id IS NOT NULL OR er.user_principal_id IS NOT NULL)
              AND (:q = '' OR ib.provider_subject ILIKE :pattern OR au.email ILIKE :pattern
                   OR md.organizations ILIKE :pattern)
            ORDER BY er.last_seen DESC NULLS LAST, au.email ASC
            OFFSET :offset LIMIT :limit
        """), {"q": q.strip(), "pattern": f"%{q.strip()}%", "offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.directory.searched")
    return {"users": [dict(row) for row in rows], "page": page, "page_size": page_size}


@router.get("/companies")
def company_directory(authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    with SessionLocal() as db:
        rows = db.execute(text("""
            WITH member_counts AS (
              SELECT organization_id, count(DISTINCT principal_id) AS users
              FROM organization_members WHERE status='active' GROUP BY organization_id
            ), event_counts AS (
              SELECT organization_id, count(*) AS events,
                     count(*) FILTER (WHERE status IN ('failed','error')) AS failures,
                     max(event_at) AS last_activity
              FROM diagnostic_events GROUP BY organization_id
            )
            SELECT o.organization_id, o.name, o.status, o.created_at,
                   coalesce(mc.users, 0) AS users,
                   coalesce(ec.events, 0) AS events,
                   coalesce(ec.failures, 0) AS failures,
                   ec.last_activity
            FROM organizations o
            LEFT JOIN member_counts mc ON mc.organization_id=o.organization_id
            LEFT JOIN event_counts ec ON ec.organization_id=o.organization_id
            ORDER BY o.created_at DESC
        """)).mappings().all()
    _audit(actor, "company_diagnostics.companies.viewed")
    return {"companies": [dict(row) for row in rows]}


@router.get("/users/{principal_id}/timeline")
def company_user_timeline(principal_id: str, page: int = Query(1, ge=1),
                          page_size: int = Query(50, ge=1, le=100),
                          authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT e.event_id, e.event_at, e.organization_id,
                   e.branch_id, e.correlation_id, e.category, e.status,
                   e.sanitized_error, e.payload
            FROM diagnostic_events e
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
            SELECT e.event_id, e.event_at, e.organization_id,
                   e.user_principal_id, au.email, e.branch_id, e.correlation_id,
                   e.category, e.status, e.sanitized_error
            FROM diagnostic_events e
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


@router.get("/backend-requests")
def backend_requests(q: str = Query(default="", max_length=160),
                     failed_only: bool = False,
                     page: int = Query(1, ge=1),
                     page_size: int = Query(50, ge=1, le=100),
                     authorization: str | None = Header(default=None)):
    actor = _company_actor(authorization)
    offset, limit = _paging(page, page_size)
    with SessionLocal() as db:
        rows = db.execute(text("""
            SELECT e.event_id, e.created_at, e.request_id, e.method, e.route,
                   e.status_code, e.duration_ms, e.principal_id, au.email,
                   e.client_version, e.error_type, e.error_message, e.error_fingerprint
            FROM platform_backend_events e
            LEFT JOIN principals p ON p.principal_id=e.principal_id
            LEFT JOIN identity_bindings ib ON ib.principal_id=p.principal_id
              AND ib.provider='supabase' AND ib.status='active'
            LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
            WHERE (NOT :failed_only OR e.status_code >= 400)
              AND (:q = '' OR e.route ILIKE :pattern OR e.request_id ILIKE :pattern
                   OR e.error_type ILIKE :pattern OR e.error_message ILIKE :pattern
                   OR au.email ILIKE :pattern)
            ORDER BY e.created_at DESC OFFSET :offset LIMIT :limit
        """), {"failed_only": failed_only, "q": q.strip(),
               "pattern": f"%{q.strip()}%", "offset": offset, "limit": limit}).mappings().all()
    _audit(actor, "company_diagnostics.backend_requests.searched",
           {"failed_only": failed_only, "query_present": bool(q.strip())})
    return {"requests": [dict(row) for row in rows], "page": page, "page_size": page_size}


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
