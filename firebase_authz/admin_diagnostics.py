"""Server-authorized diagnostics APIs for the independent administrator portal."""
from __future__ import annotations
import csv
import hashlib
import io
import json
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from fastapi import APIRouter, Header, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text
from core.db import SessionLocal
from .supabase_auth import verify_supabase_access_token

router = APIRouter(prefix="/v1/admin", tags=["admin-diagnostics"])
diagnostic_router = APIRouter(prefix="/v1/diagnostics", tags=["diagnostics"])
SESSION_TTL = timedelta(minutes=15)
MAX_PAGE_SIZE = 100
MAX_EXPORT_ROWS = 10_000

def _claims(authorization: str | None) -> dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Authentication required.")
    try:
        return verify_supabase_access_token(authorization[7:].strip(), require_email_verified=True)
    except Exception as exc:
        raise HTTPException(401, "Session expired.") from exc

def _actor(authorization: str | None) -> dict[str, Any]:
    claims = _claims(authorization); subject = str(claims.get("sub") or claims.get("uid") or "").strip()
    with SessionLocal() as db:
        row = db.execute(text("""
            SELECT p.principal_id, om.organization_id, om.workspace_id,
                   COALESCE(MAX(CASE WHEN oa.role_id='organization_owner' THEN 1 ELSE 0 END), 0) AS owner,
                   COALESCE(sa.active, false) AS support_active,
                   sa.organization_id AS support_org, sa.branch_id AS support_branch
            FROM identity_bindings ib JOIN principals p ON p.principal_id=ib.principal_id
            JOIN organization_members om ON om.principal_id=p.principal_id AND om.status='active'
            LEFT JOIN organizational_assignments oa ON oa.principal_id=p.principal_id
              AND oa.organization_id=om.organization_id AND oa.status='active'
            LEFT JOIN diagnostic_support_admins sa ON sa.principal_id=p.principal_id AND sa.active
            WHERE ib.provider='supabase' AND ib.provider_subject=:subject
            GROUP BY p.principal_id, om.organization_id, om.workspace_id, sa.active, sa.organization_id, sa.branch_id
            ORDER BY owner DESC LIMIT 1
        """), {"subject": subject}).mappings().first()
    if not row or (not row["owner"] and (not row["support_active"] or not row["support_org"])):
        raise HTTPException(403, "Diagnostic administrator access denied.")
    return dict(row) | {"subject": subject}

def _scope(actor: dict[str, Any], organization_id: str | None = None, branch_id: str | None = None):
    org = str(actor["organization_id"])
    if organization_id and organization_id != org:
        raise HTTPException(403, "Organization scope denied.")
    if actor["support_active"] and not actor.get("owner", 0):
        if actor["support_org"] and actor["support_org"] != org:
            raise HTTPException(403, "Organization scope denied.")
        assigned = actor["support_branch"]
        if branch_id and assigned and branch_id != assigned:
            raise HTTPException(403, "Branch scope denied.")
        branch_id = assigned or branch_id
    return org, branch_id

def _audit(actor: dict[str, Any], action: str, metadata: dict[str, Any] | None = None, outcome="succeeded"):
    safe = dict(metadata or {})
    if actor.get("support_branch"): safe.setdefault("branch_id", actor["support_branch"])
    with SessionLocal.begin() as db:
        db.execute(text("""INSERT INTO audit_events(event_id,organization_id,actor_principal_id,action,outcome,metadata)
            VALUES (:id,:org,:actor,:action,:outcome,CAST(:metadata AS jsonb))"""),
            {"id":"audit_"+uuid.uuid4().hex,"org":actor["organization_id"],"actor":actor["principal_id"],"action":action,"outcome":outcome,"metadata":json.dumps(safe)})

def _rate_limit(actor: dict[str, Any], action: str, limit: int = 120) -> None:
    with SessionLocal() as db:
        count = db.execute(text("""SELECT count(*) FROM audit_events
            WHERE organization_id=:org AND actor_principal_id=:actor AND action=:action
              AND created_at > now() - interval '1 minute'"""),
            {"org": actor["organization_id"], "actor": actor["principal_id"], "action": action}).scalar_one()
    if count >= limit:
        raise HTTPException(429, "Diagnostic request rate limit exceeded.")

def _paging(page: int, page_size: int):
    if page < 1 or page_size < 1 or page_size > MAX_PAGE_SIZE: raise HTTPException(422, "Invalid pagination.")
    return (page - 1) * page_size, page_size

def _csv_safe(value: Any):
    value = "" if value is None else str(value)
    return "'" + value if value.startswith(("=", "+", "-", "@")) else value

class EventIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    session_id: str = Field(min_length=20, max_length=100)
    claim_secret: str = Field(min_length=32, max_length=200)
    correlation_id: str = Field(min_length=1, max_length=128)
    category: str = Field(min_length=1, max_length=80)
    status: str = Field(min_length=1, max_length=40)
    sanitized_error: str | None = Field(default=None, max_length=500)
    payload: dict[str, Any] = Field(default_factory=dict)

class SessionClaim(BaseModel):
    model_config = ConfigDict(extra="forbid")
    session_id: str = Field(min_length=20, max_length=100)
    claim_secret: str = Field(min_length=32, max_length=200)

def _hash(secret: str) -> str: return hashlib.sha256(secret.encode()).hexdigest()

class AuthenticatedEventIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    session_id: str = Field(min_length=20, max_length=100)
    correlation_id: str = Field(min_length=1, max_length=128)
    category: str = Field(min_length=1, max_length=80)
    status: str = Field(min_length=1, max_length=40)
    sanitized_error: str | None = Field(default=None, max_length=500)
    payload: dict[str, Any] = Field(default_factory=dict)

@diagnostic_router.post("/sessions")
def create_session():
    session = "diag_" + secrets.token_urlsafe(32); secret = secrets.token_urlsafe(48); now = datetime.now(timezone.utc)
    with SessionLocal.begin() as db:
        recent = db.execute(text("SELECT count(*) FROM diagnostic_sessions WHERE created_at > now() - interval '1 minute'" )).scalar_one()
        if recent >= 120: raise HTTPException(429, "Diagnostic session rate limit exceeded.")
        db.execute(text("INSERT INTO diagnostic_sessions(session_id,claim_token_hash,expires_at) VALUES (:session,:hash,:expires)"), {"session":session,"hash":_hash(secret),"expires":now+SESSION_TTL})
    return {"support_reference": session, "claim_secret": secret, "expires_at": (now+SESSION_TTL).isoformat()}

@diagnostic_router.post("/sessions/claim")
def claim_session(item: SessionClaim, authorization: str | None = Header(default=None)):
    claims = _claims(authorization); subject = str(claims.get("sub") or claims.get("uid") or "")
    with SessionLocal.begin() as db:
        rows = db.execute(text("""SELECT s.session_id,s.expires_at,s.claimed_at,p.principal_id,om.organization_id,
            MIN(oa.location_id) AS location_id, COUNT(DISTINCT oa.location_id) AS assignment_branches
            FROM diagnostic_sessions s JOIN identity_bindings ib ON ib.provider='supabase' AND ib.provider_subject=:subject
            JOIN principals p ON p.principal_id=ib.principal_id JOIN organization_members om ON om.principal_id=p.principal_id AND om.status='active'
            LEFT JOIN organizational_assignments oa ON oa.principal_id=p.principal_id AND oa.organization_id=om.organization_id AND oa.status='active'
            WHERE s.session_id=:session AND s.claim_token_hash=:hash
            GROUP BY s.session_id,s.expires_at,s.claimed_at,p.principal_id,om.organization_id
            FOR UPDATE"""), {"session":item.session_id,"hash":_hash(item.claim_secret),"subject":subject}).mappings().all()
        if len(rows) != 1 or rows[0]["assignment_branches"] > 1: raise HTTPException(403,"Diagnostic session identity scope is ambiguous or invalid.")
        row = rows[0]
        if row["claimed_at"] or row["expires_at"] <= datetime.now(timezone.utc): raise HTTPException(403,"Diagnostic session is invalid or expired.")
        db.execute(text("UPDATE diagnostic_sessions SET user_principal_id=:principal,organization_id=:org,claimed_at=now(),claim_token_hash=NULL WHERE session_id=:session"), {"principal":row["principal_id"],"org":row["organization_id"],"session":item.session_id})
        db.execute(text("UPDATE diagnostic_events SET organization_id=:org,user_principal_id=:principal,branch_id=:branch WHERE session_id=:session AND organization_id IS NULL"), {"org":row["organization_id"],"principal":row["principal_id"],"branch":row.get("location_id"),"session":item.session_id})
    return {"claimed": True}

@diagnostic_router.post("/events")
def anonymous_event(item: EventIn):
    with SessionLocal.begin() as db:
        row = db.execute(text("SELECT session_id,organization_id,user_principal_id,expires_at,claim_token_hash FROM diagnostic_sessions WHERE session_id=:session FOR UPDATE"), {"session":item.session_id}).mappings().first()
        if not row or row["expires_at"] <= datetime.now(timezone.utc) or row["claim_token_hash"] != _hash(item.claim_secret): raise HTTPException(403,"Diagnostic session is invalid or expired.")
        count = db.execute(text("SELECT count(*) FROM diagnostic_events WHERE session_id=:session AND created_at > now() - interval '1 minute'"), {"session":item.session_id}).scalar_one()
        if count >= 60: raise HTTPException(429,"Diagnostic event rate limit exceeded.")
        db.execute(text("""INSERT INTO diagnostic_events(event_id,session_id,organization_id,user_principal_id,correlation_id,category,status,sanitized_error,payload)
            VALUES (:id,:session,:org,:principal,:corr,:category,:status,:error,CAST(:payload AS jsonb))"""), {"id":"evt_"+uuid.uuid4().hex,"session":item.session_id,"org":row["organization_id"],"principal":row["user_principal_id"],"corr":item.correlation_id,"category":item.category,"status":item.status,"error":item.sanitized_error or "","payload":json.dumps(item.payload)})
    return {"accepted": True}

@router.post("/events")
def authenticated_event(item: AuthenticatedEventIn, authorization: str | None = Header(default=None)):
    actor = _actor(authorization); _rate_limit(actor, "diagnostic.event.ingested", 600)
    with SessionLocal.begin() as db:
        valid = db.execute(text("""SELECT 1 FROM diagnostic_sessions
            WHERE session_id=:session AND organization_id=:org AND (user_principal_id=:principal OR user_principal_id IS NULL)
              AND expires_at > now()"""), {"session":item.session_id,"org":actor["organization_id"],"principal":actor["principal_id"]}).scalar_one_or_none()
        if not valid: raise HTTPException(403, "Diagnostic session is invalid or outside your scope.")
        db.execute(text("""INSERT INTO diagnostic_events(event_id,session_id,organization_id,user_principal_id,branch_id,correlation_id,category,status,sanitized_error,payload)
            VALUES (:id,:session,:org,:principal,:branch,:corr,:category,:status,:error,CAST(:payload AS jsonb))"""), {"id":"evt_"+uuid.uuid4().hex,"session":item.session_id,"org":actor["organization_id"],"principal":actor["principal_id"],"branch":actor.get("support_branch"),"corr":item.correlation_id,"category":item.category,"status":item.status,"error":item.sanitized_error or "","payload":json.dumps(item.payload)})
    return {"accepted": True}

@router.get("/overview")
def overview(branch_id: str | None = None, authorization: str | None = Header(default=None)):
    actor=_actor(authorization); org,branch=_scope(actor,branch_id=branch_id); _audit(actor,"diagnostic.overview.viewed",{"branch_id":branch})
    with SessionLocal() as db: row=db.execute(text("SELECT count(*) total_events,count(DISTINCT user_principal_id) users FROM diagnostic_events WHERE organization_id=:org AND (:branch IS NULL OR branch_id=:branch)"),{"org":org,"branch":branch}).mappings().one()
    return {"organization_id":org,"total_events":row["total_events"],"users":row["users"]}

@router.get("/users")
def users(q: str=Query(default="",max_length=160), branch_id: str|None=None, page: int=Query(1,ge=1), page_size: int=Query(50,ge=1,le=MAX_PAGE_SIZE), organization_id: str|None=None, authorization: str|None=Header(default=None)):
    actor=_actor(authorization); org,branch=_scope(actor,organization_id,branch_id); offset,limit=_paging(page,page_size); _audit(actor,"diagnostic.directory.searched",{"branch_id":branch})
    with SessionLocal() as db:
        rows=db.execute(text("""SELECT p.principal_id,ib.provider_subject AS user_id,au.email,oa.location_id AS branch_id
            FROM principals p JOIN identity_bindings ib ON ib.principal_id=p.principal_id AND ib.provider='supabase'
            JOIN organization_members target_member ON target_member.principal_id=p.principal_id AND target_member.organization_id=:org AND target_member.status='active'
            LEFT JOIN organizational_assignments oa ON oa.principal_id=p.principal_id AND oa.organization_id=:org AND oa.status='active'
            LEFT JOIN auth.users au ON au.id::text=ib.provider_subject
            WHERE (ib.provider_subject ILIKE :q OR au.email ILIKE :q) AND (:branch IS NULL OR oa.location_id=:branch)
            ORDER BY ib.provider_subject OFFSET :offset LIMIT :limit"""),{"org":org,"q":f"%{q.strip()}%","branch":branch,"offset":offset,"limit":limit}).mappings().all()
    return {"users":[dict(row) for row in rows],"page":page,"page_size":page_size}

@router.get("/users/{principal_id}/timeline")
def timeline(principal_id: str, branch_id: str|None=None, page: int=Query(1,ge=1), page_size: int=Query(50,ge=1,le=MAX_PAGE_SIZE), authorization: str|None=Header(default=None)):
    actor=_actor(authorization); org,branch=_scope(actor,branch_id=branch_id); offset,limit=_paging(page,page_size); _audit(actor,"diagnostic.timeline.viewed",{"branch_id":branch})
    with SessionLocal() as db:
        rows=db.execute(text("""SELECT e.event_id,e.event_at,e.correlation_id,e.category,e.status,e.sanitized_error FROM diagnostic_events e
            JOIN organization_members target_member ON target_member.principal_id=e.user_principal_id AND target_member.organization_id=:org AND target_member.status='active'
            WHERE e.organization_id=:org AND e.user_principal_id=:principal AND (:branch IS NULL OR e.branch_id=:branch)
            ORDER BY e.event_at DESC OFFSET :offset LIMIT :limit"""),{"org":org,"principal":principal_id,"branch":branch,"offset":offset,"limit":limit}).mappings().all()
    return {"events":[dict(row) for row in rows],"page":page,"page_size":page_size}

def _export_rows(actor, branch_id):
    org,branch=_scope(actor,branch_id=branch_id)
    with SessionLocal() as db:
        return [dict(row) for row in db.execute(text("""SELECT e.event_id,e.event_at,e.user_principal_id,e.correlation_id,e.category,e.status,e.sanitized_error FROM diagnostic_events e
            JOIN organization_members target_member ON target_member.principal_id=e.user_principal_id AND target_member.organization_id=:org AND target_member.status='active'
            WHERE e.organization_id=:org AND (:branch IS NULL OR e.branch_id=:branch) ORDER BY e.event_at DESC LIMIT :limit"""),{"org":org,"branch":branch,"limit":MAX_EXPORT_ROWS}).mappings().all()]

@router.get("/export")
def export_report(format: str=Query("json",pattern="^(json|csv)$"), branch_id: str|None=None, authorization: str|None=Header(default=None)):
    actor=_actor(authorization); rows=_export_rows(actor,branch_id); _audit(actor,"diagnostic.report.exported",{"format":format,"branch_id":branch_id})
    if format=="csv":
        out=io.StringIO(); fields=list(rows[0]) if rows else ["event_id"]; writer=csv.DictWriter(out,fieldnames=fields); writer.writeheader(); writer.writerows({k:_csv_safe(v) for k,v in row.items()} for row in rows)
        return StreamingResponse(iter([out.getvalue()]),media_type="text/csv",headers={"Content-Disposition":"attachment; filename=diagnostics.csv"})
    return rows

@router.get("/support/search")
def support_search(q: str=Query(...,min_length=2,max_length=160), branch_id: str|None=None, page: int=Query(1,ge=1), page_size: int=Query(50,ge=1,le=MAX_PAGE_SIZE), authorization: str|None=Header(default=None)):
    actor=_actor(authorization); _rate_limit(actor,"diagnostic.support_reference.searched"); org,branch=_scope(actor,branch_id=branch_id); offset,limit=_paging(page,page_size); _audit(actor,"diagnostic.support_reference.searched",{"branch_id":branch})
    with SessionLocal() as db: rows=db.execute(text("SELECT event_id,event_at,correlation_id,category,status FROM diagnostic_events WHERE organization_id=:org AND (:branch IS NULL OR branch_id=:branch) AND (correlation_id ILIKE :q OR category ILIKE :q) ORDER BY event_at DESC OFFSET :offset LIMIT :limit"),{"org":org,"branch":branch,"q":f"%{q}%","offset":offset,"limit":limit}).mappings().all()
    return {"references":[dict(row) for row in rows],"page":page,"page_size":page_size}

@router.get("/audit")
def audit_history(branch_id: str|None=None, page: int=Query(1,ge=1), page_size: int=Query(50,ge=1,le=MAX_PAGE_SIZE), authorization: str|None=Header(default=None)):
    actor=_actor(authorization); org,branch=_scope(actor,branch_id=branch_id); offset,limit=_paging(page,page_size)
    with SessionLocal() as db: rows=db.execute(text("SELECT event_id,action,outcome,metadata,created_at FROM audit_events WHERE organization_id=:org AND action LIKE 'diagnostic.%' AND (:branch IS NULL OR metadata->>'branch_id'=:branch) ORDER BY created_at DESC OFFSET :offset LIMIT :limit"),{"org":org,"branch":branch,"offset":offset,"limit":limit}).mappings().all()
    return {"audit":[dict(row) for row in rows],"page":page,"page_size":page_size}
