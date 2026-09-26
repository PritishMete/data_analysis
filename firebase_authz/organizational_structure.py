"""Organizational structure persistence for the relational company hierarchy.

Authentication identifies the person; organizational assignments identify that
person's role in a company/location/section context.
"""
from __future__ import annotations
from typing import Any
import uuid
from sqlalchemy import text
from core.db import SessionLocal
from .service import AuthzError

ALLOWED_ASSIGNMENT_ROLES={"manager","team_lead","employee"}
ACTIVE_STATUSES={"active","inactive"}

def _id(prefix:str)->str:
    return f"{prefix}_{uuid.uuid4().hex}"

def _clean_name(value:str, field:str, max_length:int)->str:
    value=str(value or "").strip()
    if not 1<=len(value)<=max_length or any(ord(c)<32 or ord(c)==127 for c in value):
        raise ValueError(f"{field} must be between 1 and {max_length} characters.")
    return value

def _actor(db, claims:dict[str,Any], workspace_id:str):
    from .supabase_provider import _principal_for_claims
    workspace_id=str(workspace_id or "").strip()
    if not workspace_id: raise ValueError("Workspace authorization context required.")
    actor=_principal_for_claims(db,claims,workspace_id)
    if not actor or actor["status"]!="active": raise AuthzError("Workspace authorization denied.")
    return actor,workspace_id

def _can_manage_structure(db, organization_id:str, principal_id:str)->bool:
    return db.execute(text("""SELECT 1 FROM member_roles
        WHERE organization_id=:org AND principal_id=:principal
          AND role_id IN ('organization_owner','manager') LIMIT 1"""),
        {"org":organization_id,"principal":principal_id}).scalar_one_or_none() is not None

def _require_manager_or_owner(db,claims,workspace_id):
    actor,org=_actor(db,claims,workspace_id)
    if not _can_manage_structure(db,org,actor["principal_id"]):
        raise AuthzError("Organizational structure management denied.")
    return actor,org

def list_locations(claims,workspace_id,include_inactive=False):
    with SessionLocal() as db:
        actor,org=_actor(db,claims,workspace_id)
        rows=db.execute(text("""SELECT location_id,organization_id,name,status,created_at,updated_at
            FROM locations WHERE organization_id=:org AND (:include_inactive OR status='active')
            ORDER BY lower(name),location_id"""),
            {"org":org,"include_inactive":include_inactive,"location":location_id}).mappings().all()
    return {"organization_id":org,"locations":[dict(r) for r in rows]}

def create_location(claims,workspace_id,name):
    name=_clean_name(name,"Location name",160)
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        location_id=_id("loc")
        try:
            db.execute(text("INSERT INTO locations(location_id,organization_id,name) VALUES (:id,:org,:name)"),
                       {"id":location_id,"org":org,"name":name})
        except Exception as exc:
            if "unique" in str(exc).lower(): raise ValueError("An active location with this name already exists.") from exc
            raise
    return {"location_id":location_id,"organization_id":org,"name":name,"status":"active"}

def update_location(claims,workspace_id,location_id,name=None,status=None):
    if status is not None and status not in ACTIVE_STATUSES: raise ValueError("Invalid location status.")
    if name is None and status is None: raise ValueError("At least one location field must be supplied.")
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        row=db.execute(text("""SELECT name,status FROM locations
            WHERE organization_id=:org AND location_id=:location FOR UPDATE"""),
            {"org":org,"location":location_id}).mappings().first()
        if not row: raise AuthzError("Location is not accessible.")
        new_name=_clean_name(name,"Location name",160) if name is not None else row["name"]
        new_status=status or row["status"]
        try:
            db.execute(text("""UPDATE locations SET name=:name,status=:status,updated_at=now()
                WHERE organization_id=:org AND location_id=:location"""),
                {"org":org,"location":location_id,"name":new_name,"status":new_status})
        except Exception as exc:
            if "unique" in str(exc).lower(): raise ValueError("An active location with this name already exists.") from exc
            raise
    return {"location_id":location_id,"organization_id":org,"name":new_name,"status":new_status}

def list_sections(claims,workspace_id,include_inactive=False,location_id=None):
    with SessionLocal() as db:
        actor,org=_actor(db,claims,workspace_id)
        rows=db.execute(text("""SELECT section_id,organization_id,location_id,name,status,created_at,updated_at
            FROM sections WHERE organization_id=:org
              AND (:include_inactive OR status='active')
              AND (:location IS NULL OR location_id=:location)
            ORDER BY location_id,lower(name),section_id"""),
            {"org":org,"include_inactive":include_inactive}).mappings().all()
    return {"organization_id":org,"sections":[dict(r) for r in rows]}

def create_section(claims,workspace_id,name,location_id):
    name=_clean_name(name,"Section name",120)
    location_id=str(location_id or "").strip()
    if not location_id: raise ValueError("location_id is required for a section.")
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        if not db.execute(text("""SELECT 1 FROM locations
            WHERE organization_id=:org AND location_id=:location AND status='active'"""),
            {"org":org,"location":location_id}).scalar_one_or_none():
            raise AuthzError("Location is not accessible.")
        section_id=_id("sec")
        try:
            db.execute(text("""INSERT INTO sections(section_id,organization_id,location_id,name)
                VALUES (:id,:org,:location,:name)"""),
                       {"id":section_id,"org":org,"location":location_id,"name":name})
        except Exception as exc:
            if "unique" in str(exc).lower(): raise ValueError("An active section with this name already exists.") from exc
            raise
    return {"section_id":section_id,"organization_id":org,"location_id":location_id,"name":name,"status":"active"}

def update_section(claims,workspace_id,section_id,name=None,status=None):
    if status is not None and status not in ACTIVE_STATUSES: raise ValueError("Invalid section status.")
    if name is None and status is None: raise ValueError("At least one section field must be supplied.")
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        row=db.execute(text("""SELECT name,status,location_id FROM sections
            WHERE organization_id=:org AND section_id=:section FOR UPDATE"""),
            {"org":org,"section":section_id}).mappings().first()
        if not row: raise AuthzError("Section is not accessible.")
        new_name=_clean_name(name,"Section name",120) if name is not None else row["name"]
        new_status=status or row["status"]
        try:
            db.execute(text("""UPDATE sections SET name=:name,status=:status,updated_at=now()
                WHERE organization_id=:org AND section_id=:section"""),
                {"org":org,"section":section_id,"name":new_name,"status":new_status})
        except Exception as exc:
            if "unique" in str(exc).lower(): raise ValueError("An active section with this name already exists.") from exc
            raise
    return {"section_id":section_id,"organization_id":org,"location_id":row["location_id"],"name":new_name,"status":new_status}

def list_assignments(claims,workspace_id,include_inactive=False):
    with SessionLocal() as db:
        actor,org=_actor(db,claims,workspace_id)
        rows=db.execute(text("""SELECT a.assignment_id,a.organization_id,a.principal_id,a.location_id,
            l.name AS location_name,a.role_id,a.section_id,s.name AS section_name,
            s.location_id AS section_location_id,
            a.reports_to_assignment_id,a.status,a.created_at,a.updated_at
            FROM organizational_assignments a
            LEFT JOIN locations l ON l.organization_id=a.organization_id AND l.location_id=a.location_id
            LEFT JOIN sections s ON s.organization_id=a.organization_id AND s.section_id=a.section_id
            WHERE a.organization_id=:org AND (:include_inactive OR a.status='active')
            ORDER BY a.role_id,a.location_id NULLS LAST,a.section_id NULLS LAST,a.principal_id"""),
            {"org":org,"include_inactive":include_inactive}).mappings().all()
    return {"organization_id":org,"assignments":[dict(r) for r in rows]}

def create_assignment(claims,workspace_id,principal_id,role_id,location_id=None,section_id=None,reports_to_assignment_id=None):
    principal_id=str(principal_id or "").strip()
    role_id=str(role_id or "").strip()
    location_id=str(location_id or "").strip() or None
    section_id=str(section_id or "").strip() or None
    reports_to_assignment_id=str(reports_to_assignment_id or "").strip() or None
    if not principal_id: raise ValueError("principal_id is required.")
    if role_id not in ALLOWED_ASSIGNMENT_ROLES: raise ValueError("Only manager, team_lead, and employee assignments are supported.")
    if role_id=="manager" and (not location_id or section_id or reports_to_assignment_id):
        raise ValueError("A Manager assignment requires a location and cannot have a section or parent assignment.")
    if role_id in {"team_lead","employee"} and (not location_id or not section_id):
        raise ValueError(f"A {role_id} assignment requires a location and section.")
    if role_id in {"team_lead","employee"} and not reports_to_assignment_id:
        raise ValueError(f"A {role_id} assignment requires a parent assignment.")
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        member=db.execute(text("""SELECT 1 FROM organization_members
            WHERE organization_id=:org AND principal_id=:principal AND status='active'"""),
            {"org":org,"principal":principal_id}).scalar_one_or_none()
        if not member: raise AuthzError("Assignment target must be an active member of this company.")
        if location_id and not db.execute(text("""SELECT 1 FROM locations
            WHERE organization_id=:org AND location_id=:location AND status='active'"""),
            {"org":org,"location":location_id}).scalar_one_or_none():
            raise AuthzError("Location is not accessible.")
        if section_id and not db.execute(text("""SELECT 1 FROM sections
            WHERE organization_id=:org AND section_id=:section AND status='active'
              AND location_id=:location"""),
            {"org":org,"section":section_id,"location":location_id}).scalar_one_or_none():
            raise AuthzError("Section is not accessible.")
        if reports_to_assignment_id:
            parent=db.execute(text("""SELECT assignment_id,role_id,location_id,section_id
                FROM organizational_assignments
                WHERE organization_id=:org AND assignment_id=:assignment AND status='active' FOR UPDATE"""),
                {"org":org,"assignment":reports_to_assignment_id}).mappings().first()
            if not parent: raise AuthzError("Parent assignment is not accessible.")
            if role_id=="team_lead" and (parent["role_id"]!="manager" or parent["location_id"]!=location_id):
                raise AuthzError("A Team Lead must report to the Manager of the same location.")
            if role_id=="employee" and (parent["role_id"]!="team_lead" or parent["location_id"]!=location_id or parent["section_id"]!=section_id):
                raise AuthzError("An Employee must report to a Team Lead in the same location and section.")
        assignment_id=_id("asg")
        try:
            db.execute(text("""INSERT INTO organizational_assignments
                (assignment_id,organization_id,principal_id,location_id,role_id,section_id,reports_to_assignment_id)
                VALUES (:id,:org,:principal,:location,:role,:section,:parent)"""),
                {"id":assignment_id,"org":org,"principal":principal_id,"location":location_id,
                 "role":role_id,"section":section_id,"parent":reports_to_assignment_id})
        except Exception as exc:
            msg=str(exc).lower()
            if "unique" in msg:
                if role_id=="manager": raise ValueError("This location already has an active Manager.") from exc
                raise ValueError("An active assignment with this person and organizational context already exists.") from exc
            raise
    return {"assignment_id":assignment_id,"organization_id":org,"principal_id":principal_id,
            "location_id":location_id,"role_id":role_id,"section_id":section_id,
            "reports_to_assignment_id":reports_to_assignment_id,"status":"active"}

def update_assignment_status(claims,workspace_id,assignment_id,status):
    if status not in ACTIVE_STATUSES: raise ValueError("Invalid assignment status.")
    with SessionLocal.begin() as db:
        actor,org=_require_manager_or_owner(db,claims,workspace_id)
        row=db.execute(text("""SELECT assignment_id FROM organizational_assignments
            WHERE organization_id=:org AND assignment_id=:assignment FOR UPDATE"""),
            {"org":org,"assignment":assignment_id}).mappings().first()
        if not row: raise AuthzError("Assignment is not accessible.")
        db.execute(text("""UPDATE organizational_assignments SET status=:status,updated_at=now()
            WHERE organization_id=:org AND assignment_id=:assignment"""),
            {"org":org,"status":status,"assignment":assignment_id})
    return {"assignment_id":assignment_id,"organization_id":org,"status":status}
