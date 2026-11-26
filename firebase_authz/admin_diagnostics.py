"""Administrator-only diagnostic APIs. Authorization is always resolved from DB state."""
from __future__ import annotations
import csv, io, json, secrets, hashlib, uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from fastapi import APIRouter, Header, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict
from sqlalchemy import text
from core.db import SessionLocal
from .supabase_auth import verify_supabase_access_token

router = APIRouter(prefix="/v1/admin", tags=["admin-diagnostics"])

def _claims(authorization: str | None) -> dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Authentication required.")
    try:
        return verify_supabase_access_token(authorization[7:].strip(), require_email_verified=True)
    except Exception as exc:
        raise HTTPException(401, "Session expired.") from exc

def _actor(authorization: str | None) -> dict[str, Any]:
    claims = _claims(authorization)
    subject = str(claims.get("sub") or claims.get("uid") or "")
    with SessionLocal() as db:
        row = db.execute(text("""SELECT p.principal_id, om.organization_id, om.workspace_id,
            COALESCE(oa.role_id, '') role_id, COALESCE(sa.active, false) support_active,
            sa.organization_id support_org, sa.branch_id support_branch
            FROM identity_bindings ib JOIN principals p ON p.principal_id=ib.principal_id
            JOIN organization_members om ON om.principal_id=p.principal_id AND om.status='active'
            LEFT JOIN organizational_assignments oa ON oa.principal_id=p.principal_id AND oa.organization_id=om.organization_id AND oa.status='active'
            LEFT JOIN diagnostic_support_admins sa ON sa.principal_id=p.principal_id
            WHERE ib.provider='supabase' AND ib.provider_subject=:subject
            ORDER BY CASE WHEN oa.role_id='organization_owner' THEN 0 ELSE 1 END LIMIT 1"""), {"subject": subject}).mappings().first()
    if not row or not (row["role_id"] == "organization_owner" or row["support_active"]):
        raise HTTPException(403, "Diagnostic administrator access denied.")
    return dict(row) | {"subject": subject}

def _scope(actor: dict[str, Any], organization_id: str | None, branch_id: str | None) -> tuple[str, str | None]:
    org = organization_id or actor["organization_id"]
    if org != actor["organization_id"] and actor["role_id"] != "organization_owner":
        raise HTTPException(403, "Organization scope denied.")
    if actor["support_active"] and actor["role_id"] != "organization_owner":
        if actor["support_org"] and actor["support_org"] != org: raise HTTPException(403, "Organization scope denied.")
        if actor["support_branch"] and branch_id and actor["support_branch"] != branch_id: raise HTTPException(403, "Branch scope denied.")
        branch_id = branch_id or actor["support_branch"]
    return org, branch_id

def _audit(actor: dict[str, Any], action: str, metadata: dict[str, Any] | None = None) -> None:
    with SessionLocal.begin() as db:
        db.execute(text("INSERT INTO audit_events(event_id, organization_id, actor_principal_id, action, outcome, metadata) VALUES (:id,:org,:actor,:action,'succeeded',CAST(:metadata AS jsonb))"), {"id": "audit_"+uuid.uuid4().hex, "org": actor["organization_id"], "actor": actor["principal_id"], "action": action, "metadata": json.dumps(metadata or {})})

class EventIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    session_id: str
    correlation_id: str
    category: str
    status: str
    sanitized_error: str | None = None
    payload: dict[str, Any] = {}

@router.get("/overview")
def overview(authorization: str | None = Header(default=None)):
    actor = _actor(authorization)
    _audit(actor, "diagnostic.overview.viewed")
    with SessionLocal() as db:
        row = db.execute(text("SELECT count(*) total_events, count(DISTINCT user_principal_id) users FROM diagnostic_events WHERE organization_id=:org"), {"org": actor["organization_id"]}).mappings().one()
    return {"organization_id": actor["organization_id"], "total_events": row["total_events"], "users": row["users"]}

@router.get("/users")
def users(q: str = Query(default="", max_length=160), organization_id: str | None = None, branch_id: str | None = None, authorization: str | None = Header(default=None)):
    actor = _actor(authorization); org, branch = _scope(actor, organization_id, branch_id)
    _audit(actor, "diagnostic.directory.searched", {"query": q[:80], "branch_id": branch})
    pattern = f"%{q.strip()}%"
    with SessionLocal() as db:
        rows = db.execute(text("""SELECT p.principal_id, ib.provider_subject user_id, COALESCE(amp.full_name_ciphertext, '') display_name,
          COALESCE(au.email, '') email, oa.location_id branch_id
          FROM principals p JOIN identity_bindings ib ON ib.principal_id=p.principal_id
          LEFT JOIN organization_member_profiles amp ON amp.principal_id=p.principal_id AND amp.organization_id=:org
          LEFT JOIN organizational_assignments oa ON oa.principal_id=p.principal_id AND oa.organization_id=:org AND oa.status='active'
          LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
          WHERE ib.provider='supabase' AND (ib.provider_subject ILIKE :q OR au.email ILIKE :q)
            AND (:branch IS NULL OR oa.location_id=:branch) LIMIT 100"""), {"org": org, "q": pattern, "branch": branch}).mappings().all()
    return {"users": [dict(r) for r in rows]}

@router.get("/users/{principal_id}/timeline")
def timeline(principal_id: str, authorization: str | None = Header(default=None)):
    actor = _actor(authorization)
    _audit(actor, "diagnostic.timeline.viewed", {"principal_id": principal_id})
    with SessionLocal() as db:
        rows = db.execute(text("SELECT event_id, event_at, correlation_id, category, status, sanitized_error FROM diagnostic_events WHERE organization_id=:org AND user_principal_id=:principal ORDER BY event_at DESC LIMIT 500"), {"org": actor["organization_id"], "principal": principal_id}).mappings().all()
    return {"events": [dict(r) for r in rows]}

@router.get("/export")
def export_report(format: str = Query("json", pattern="^(json|csv)$"), authorization: str | None = Header(default=None)):
    actor = _actor(authorization)
    _audit(actor, "diagnostic.report.exported", {"format": format})
    with SessionLocal() as db:
        rows = [dict(r) for r in db.execute(text("SELECT event_id, event_at, user_principal_id, correlation_id, category, status, sanitized_error FROM diagnostic_events WHERE organization_id=:org ORDER BY event_at DESC LIMIT 10000"), {"org": actor["organization_id"]}).mappings().all()]
    if format == "csv":
        out = io.StringIO(); writer = csv.DictWriter(out, fieldnames=rows[0].keys() if rows else ["event_id"]); writer.writeheader(); writer.writerows(rows)
        return StreamingResponse(iter([out.getvalue()]), media_type="text/csv", headers={"Content-Disposition": "attachment; filename=diagnostics.csv"})
    return rows

@router.get("/support/search")
def support_search(q: str = Query(..., min_length=2, max_length=160), authorization: str | None = Header(default=None)):
    actor = _actor(authorization); _audit(actor, "diagnostic.support_reference.searched", {"query": q[:80]})
    return {"references": []}

@router.get("/audit")
def audit_history(authorization: str | None = Header(default=None)):
    actor = _actor(authorization)
    with SessionLocal() as db:
        rows = db.execute(text("SELECT event_id, action, outcome, metadata, created_at FROM audit_events WHERE organization_id=:org AND action LIKE 'diagnostic.%' ORDER BY created_at DESC LIMIT 500"), {"org": actor["organization_id"]}).mappings().all()
    return {"audit": [dict(r) for r in rows]}

@router.post("/events")
def event(item: EventIn, authorization: str | None = Header(default=None)):
    actor = _actor(authorization)
    with SessionLocal.begin() as db:
        db.execute(text("INSERT INTO diagnostic_events(event_id,session_id,organization_id,user_principal_id,correlation_id,category,status,sanitized_error,payload) VALUES (:id,:session,:org,NULL,:corr,:cat,:status,:error,CAST(:payload AS jsonb))"), {"id": "evt_"+uuid.uuid4().hex, "session": item.session_id, "org": actor["organization_id"], "corr": item.correlation_id[:128], "cat": item.category[:80], "status": item.status[:40], "error": (item.sanitized_error or "")[:500], "payload": json.dumps(item.payload)})
    return {"accepted": True}
