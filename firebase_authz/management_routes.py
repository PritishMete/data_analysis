"""Domain-specific management API.

These endpoints coexist with /v1/authz/management so the legacy management
snapshot remains backward compatible while new Flutter management features can
consume normalized business-domain resources.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, ConfigDict

from .service import AuthzError, AuthenticationRequired
from .supabase_auth import verify_supabase_access_token
from .management_domain import (
    ManagementConflict,
    assign_manager,
    assign_team_lead,
    create_location,
    create_section,
    list_assignments,
    get_assignment_profile,
    list_audit_events,
    list_locations,
    list_people,
    list_sections,
    management_overview,
    replace_manager,
    set_reporting_relationship,
    request_team_lead_assignment,
    list_team_lead_requests,
    decide_team_lead_request,
)
from .supabase_provider import request_dataset_copy, list_copy_requests, approve_copy_request, assign_working_copy, list_dataset_catalog
from .gmail_invitation_email import (
    gmail_connection_url, complete_gmail_connection, get_branch_email_settings,
    update_branch_sender_name,
)

router = APIRouter(prefix="/v1/authz/management", tags=["management"])


def _token(value: str | None) -> str:
    if not value or not value.startswith("Bearer "):
        raise AuthenticationRequired("Authentication required.")
    return value[7:].strip()


def _claims(authorization: str | None) -> dict:
    try:
        token = _token(authorization)
        provider = os.environ.get("AUTHN_PROVIDER_MODE", "firebase").strip().lower()
        if provider == "supabase":
            return verify_supabase_access_token(token, require_email_verified=True)
        from .service import verify_id_token, require_email_verified
        return require_email_verified(verify_id_token(token))
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc)) from exc


def _workspace(value: str | None) -> str:
    workspace_id = str(value or "").strip()
    if not workspace_id:
        raise HTTPException(400, "Workspace authorization context required.")
    return workspace_id


class LocationCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    branch_identifier: str


class SectionCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    location_id: str
    name: str


class ManagerAssignmentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    location_id: str
    principal_id: str


class TeamLeadAssignmentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    location_id: str
    section_id: str
    principal_id: str
    reports_to_assignment_id: str | None = None


class ReportingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    assignment_id: str
    reports_to_assignment_id: str | None = None


def _dispatch(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc)) from exc
    except ManagementConflict as exc:
        raise HTTPException(409, str(exc)) from exc
    except AuthzError as exc:
        raise HTTPException(403, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


@router.get("/overview")
def overview(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(management_overview, _claims(authorization), _workspace(workspace_id))


@router.get("/locations")
def locations(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"locations": _dispatch(list_locations, _claims(authorization), _workspace(workspace_id))}


@router.post("/locations")
def location_create(
    req: LocationCreateRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(create_location, _claims(authorization), _workspace(workspace_id), req.name, req.branch_identifier)


@router.get("/sections")
def sections(
    location_id: str | None = Query(default=None),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"sections": _dispatch(list_sections, _claims(authorization), _workspace(workspace_id), location_id)}


@router.post("/sections")
def section_create(
    req: SectionCreateRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(create_section, _claims(authorization), _workspace(workspace_id), req.location_id, req.name)


@router.get("/people")
def people(
    search: str | None = Query(default=None),
    role: str | None = Query(default=None),
    location_id: str | None = Query(default=None),
    section_id: str | None = Query(default=None),
    status: str | None = Query(default=None),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"people": _dispatch(
        list_people, _claims(authorization), _workspace(workspace_id),
        search, role, location_id, section_id, status,
    )}


@router.get("/assignments")
def assignments(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"assignments": _dispatch(list_assignments, _claims(authorization), _workspace(workspace_id))}


@router.get("/assignments/{assignment_id}/profile")
def assignment_profile(
    assignment_id: str,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        get_assignment_profile,
        _claims(authorization),
        _workspace(workspace_id),
        assignment_id,
    )


@router.post("/assignments/manager")
def manager_assign(
    req: ManagerAssignmentRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(assign_manager, _claims(authorization), _workspace(workspace_id), req.location_id, req.principal_id)


@router.post("/assignments/manager/change")
def manager_change(
    req: ManagerAssignmentRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(replace_manager, _claims(authorization), _workspace(workspace_id), req.location_id, req.principal_id)


@router.post("/assignments/team-lead")
def team_lead_assign(
    req: TeamLeadAssignmentRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        assign_team_lead, _claims(authorization), _workspace(workspace_id),
        req.location_id, req.section_id, req.principal_id, req.reports_to_assignment_id,
    )


@router.get("/assignments/team-lead/requests")
def team_lead_requests(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"requests": _dispatch(list_team_lead_requests, _claims(authorization), _workspace(workspace_id))}


@router.post("/assignments/team-lead/request")
def team_lead_request(
    req: TeamLeadAssignmentRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(request_team_lead_assignment, _claims(authorization), _workspace(workspace_id), req.location_id, req.section_id, req.principal_id, req.reports_to_assignment_id)


@router.post("/assignments/team-lead/requests/{request_id}/decision")
def team_lead_request_decision(
    request_id: str,
    approve: bool = Query(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(decide_team_lead_request, _claims(authorization), _workspace(workspace_id), request_id, approve)


@router.post("/assignments/reporting")
def reporting_change(
    req: ReportingRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        set_reporting_relationship, _claims(authorization), _workspace(workspace_id),
        req.assignment_id, req.reports_to_assignment_id,
    )


@router.get("/data-access/catalog")
def data_access_catalog(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"datasets": _dispatch(list_dataset_catalog, _claims(authorization), _workspace(workspace_id))}


@router.post("/data-access/requests")
def copy_request(
    dataset_id: str = Query(...),
    note: str | None = Query(default=None),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        request_dataset_copy, _claims(authorization), _workspace(workspace_id), dataset_id, note
    )


@router.get("/data-access/requests")
def copy_requests(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"requests": _dispatch(list_copy_requests, _claims(authorization), _workspace(workspace_id))}


@router.post("/data-access/requests/{request_id}/decision")
def copy_request_decision(
    request_id: str,
    approve: bool = Query(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        approve_copy_request, _claims(authorization), _workspace(workspace_id), request_id, approve
    )


class WorkingCopyAssignmentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    working_copy_id: str
    target_uid: str


@router.post("/data-access/working-copies/assign")
def working_copy_assignment(
    req: WorkingCopyAssignmentRequest,
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        assign_working_copy, _claims(authorization), _workspace(workspace_id),
        req.working_copy_id, req.target_uid,
    )


class SenderNameRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    sender_name: str


@router.get("/email-settings")
def email_settings(
    location_id: str = Query(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        get_branch_email_settings, _claims(authorization), _workspace(workspace_id), location_id
    )


@router.post("/email-settings/connect")
def email_settings_connect(
    location_id: str = Query(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    claims = _claims(authorization)
    workspace = _workspace(workspace_id)
    principal = str(claims.get("uid") or claims.get("sub") or "")
    try:
        return {"authorization_url": gmail_connection_url(workspace, location_id, principal)}
    except (GmailConfigurationError, GmailConnectionError, AuthzError) as exc:
        raise HTTPException(400, str(exc)) from exc


@router.put("/email-settings")
def email_settings_update(
    req: SenderNameRequest,
    location_id: str = Query(...),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return _dispatch(
        update_branch_sender_name, _claims(authorization), _workspace(workspace_id),
        location_id, req.sender_name
    )


@router.get("/email-settings/callback")
def email_settings_callback(code: str = Query(...), state: str = Query(...)):
    try:
        result = complete_gmail_connection(code, state)
        return {
            "status": "connected",
            "sender_email": result["sender_email"],
            "message": "Gmail connected. Return to InsightFlow and set the sender name.",
        }
    except (GmailConfigurationError, GmailConnectionError, AuthzError) as exc:
        raise HTTPException(400, str(exc)) from exc


@router.get("/audit")
def audit(
    limit: int = Query(default=100, ge=1, le=200),
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    return {"audit": _dispatch(list_audit_events, _claims(authorization), _workspace(workspace_id), limit)}
