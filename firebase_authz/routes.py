import logging
import os
import sys
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict
from .service import AuthzError, AuthenticationRequired, BootstrapDenied, bootstrap_owner, mutate_role, upsert_role, set_resource_grant, protected_context, verify_id_token, require_email_verified, authorization as authorize_workspace, authorize_dataset, authorize_excel_mutation, register_dataset, set_dataset_grant, create_working_copy, authorize_working_copy, management_snapshot, cleanup_account, create_invitation, accept_invitation, set_membership_status, set_approved_employee, set_delegation, _user, workspace_memberships, authentication_context, authenticated_identity
from . import registration_diagnostics
from .organizational_structure import list_locations, create_location, update_location, list_sections, create_section, update_section, list_assignments, create_assignment, update_assignment_status

router=APIRouter(prefix="/v1/authz",tags=["authorization"])
logger = logging.getLogger(__name__)

class BootstrapRequest(BaseModel):
    organization_name: str

class FounderOrganizationRegistration(BaseModel):
    model_config = ConfigDict(extra="forbid")
    organization_name: str

class AuthorizationCheck(BaseModel):
    workspace_id: str
    action: str
    resource_id: str | None = None

class RoleMutation(BaseModel):
    target_uid:str
    role_id:str
    enabled:bool
    workspace_id:str

def _token(value):
    if not value or not value.startswith("Bearer "): raise HTTPException(401,"Firebase authentication required.")
    return value[7:].strip()


@router.get("/provider-diagnostics")
def provider_diagnostics(authorization: str = Header(default=None)):
    """Return minimal authenticated runtime information for provider diagnosis."""
    try:
        verify_id_token(_token(authorization))
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    provider = os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower()
    return {
        "provider": provider,
        "environment_variable_present": "AUTHZ_PERSISTENCE_PROVIDER" in os.environ,
        "backend_commit": os.environ.get("BUILD_GIT_SHA", "working-tree")[:40],
        "python_version": sys.version.split()[0],
        "module": __name__,
    }

@router.get("/me")
def me(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        claims = verify_id_token(_token(authorization))
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import authorization_context
            return {"uid": claims.get("uid"), "email": claims.get("email"), **authorization_context(claims, workspace_id.strip() if workspace_id else None)}
        uid = str(claims["uid"])
        context = authentication_context(
            uid,
            workspace_id.strip() if workspace_id else None,
            bool(claims.get("email_verified")),
            str(claims.get("email") or ""),
            authenticated_identity(claims)["provider"],
            authenticated_identity(claims)["provider_subject"],
        )
        identity = authenticated_identity(claims)
        return {
            "uid": uid,
            "email": claims.get("email"),
            "identity": identity,
            **context,
        }
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))

@router.get("/management")
def management(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        if not workspace_id:
            raise ValueError("Workspace authorization context required.")
        claims = require_email_verified(verify_id_token(_token(authorization)))
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import management_snapshot as provider_management_snapshot
            return provider_management_snapshot(claims, workspace_id.strip())
        return management_snapshot(str(claims["uid"]), workspace_id.strip(), claims)
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))

@router.get("/invitations/pending")
def pending_invitations(authorization: str = Header(default=None)):
    try:
        claims = require_email_verified(verify_id_token(_token(authorization)))
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import pending_invitations
            return {"invitations": pending_invitations(claims)}
        from .service import pending_invitations_for_email
        return {"invitations": pending_invitations_for_email(str(claims.get("email") or ""))}
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))

@router.get("/membership")
def membership(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        if not workspace_id:
            raise ValueError("Workspace authorization context required.")
        claims = require_email_verified(verify_id_token(_token(authorization)))
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import authorization_context
            context = authorization_context(claims, workspace_id.strip())
            if context["membership_status"] == "none":
                raise AuthzError("User is not a member of this organization.")
            return {"organization_id": context.get("organization_id"), "workspace_id": context.get("workspace_id"),
                    "employee_id": context.get("employee_id"), "membership_status": context["membership_status"],
                    "role_ids": context.get("role_ids", [])}
        context = authentication_context(
            str(claims["uid"]),
            workspace_id.strip(),
            True,
        )
        if context["membership_status"] == "none":
            raise AuthzError("User is not a member of this organization.")
        return {
            "organization_id": context.get("organization_id"),
            "workspace_id": context.get("workspace_id"),
            "employee_id": context.get("employee_id"),
            "membership_status": context["membership_status"],
            "role_ids": next(
                (
                    item["role_ids"]
                    for item in context["workspaces"]
                    if item["workspace_id"] == workspace_id.strip()
                ),
                [],
            ),
        }
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

@router.post("/bootstrap-owner")
@router.post("/register-company")
def bootstrap(req: BootstrapRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import register_organization
            return register_organization(require_email_verified(verify_id_token(_token(authorization))), req.organization_name)
        return bootstrap_owner(_token(authorization), req.organization_name)
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except BootstrapDenied as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@router.post("/organizations/register")
def founder_organization_register(
    req: FounderOrganizationRegistration,
    authorization: str = Header(default=None),
):
    """Public founder registration contract.

    Firebase identity is supplied only in the Authorization bearer token.
    Organization/workspace IDs, principal identity, Owner role and RBAC are
    generated and assigned by the trusted bootstrap service.
    """
    try:
        registration_diagnostics.begin()
        registration_diagnostics.stage("REGISTRATION_START")
        provider = os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower()
        logger.info("organization_register provider=%s", provider)
        registration_diagnostics.stage("AUTH_TOKEN_VERIFICATION_START")
        if provider == "supabase":
            from .supabase_provider import register_organization
            claims = verify_id_token(_token(authorization))
            registration_diagnostics.stage("JWKS_OR_TOKEN_VERIFICATION_COMPLETE")
            result = register_organization(claims, req.organization_name)
            registration_diagnostics.stage("REGISTRATION_COMPLETE")
            return result
        claims = _token(authorization)
        result = bootstrap_owner(claims, req.organization_name, allow_any_authenticated=True)
        registration_diagnostics.stage("REGISTRATION_COMPLETE")
        return result
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except BootstrapDenied as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    finally:
        registration_diagnostics.end()

@router.post("/check")
def authorization_check(req: AuthorizationCheck, authorization: str = Header(default=None)):
    try:
        token = _token(authorization)
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import authorize
            try:
                return authorize(verify_id_token(token), req.workspace_id, req.action, req.resource_id)
            except PermissionError as exc:
                raise AuthzError(str(exc)) from exc
        claims = require_email_verified(verify_id_token(token))
        uid = str(claims["uid"])
        if req.action in {"excel.mutate.original", "excel.mutate.working_copy"}:
            if not req.resource_id:
                raise AuthzError("A resource ID is required for Excel mutation authorization.")
            return authorize_excel_mutation(
                uid, req.workspace_id, req.action, req.resource_id
            )
        return authorize_workspace(uid, req.workspace_id, req.action, req.resource_id)
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

@router.post("/roles/mutate")
def role_mutation(req:RoleMutation,authorization: str=Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import mutate_role as provider_mutate_role
            return {"success": provider_mutate_role(verify_id_token(_token(authorization)), req.workspace_id, req.target_uid, req.role_id, req.enabled)}
        return {"success":mutate_role(req.target_uid,req.role_id,req.enabled,_token(authorization),req.workspace_id)}
    except AuthenticationRequired as exc: raise HTTPException(401,str(exc))
    except AuthzError as exc: raise HTTPException(403,str(exc))


class RoleUpsert(BaseModel):
    workspace_id: str
    role_id: str
    name: str
    permissions: list[str]

class InvitationRequest(BaseModel):
    workspace_id: str
    email: str
    employee_id: str
    role_id: str
    expires_at: int | None = None

class InvitationAcceptRequest(BaseModel):
    workspace_id: str
    invitation_id: str

class MembershipStatusRequest(BaseModel):
    workspace_id: str
    target_uid: str
    status: str

@router.post("/invitations")
def invitation_create(req: InvitationRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import create_invitation as provider_create_invitation
            return provider_create_invitation(verify_id_token(_token(authorization)), req.workspace_id, req.email, req.employee_id, req.role_id, req.expires_at)
        return create_invitation(
            req.workspace_id, req.email, req.employee_id, req.role_id,
            _token(authorization), req.expires_at
        )
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))

@router.post("/invitations/accept")
def invitation_accept(req: InvitationAcceptRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import accept_invitation as provider_accept_invitation
            return provider_accept_invitation(verify_id_token(_token(authorization)), req.workspace_id, req.invitation_id)
        return accept_invitation(req.workspace_id, req.invitation_id, _token(authorization))
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))

@router.post("/membership/status")
def membership_status(req: MembershipStatusRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import set_membership_status as provider_set_membership_status
            return {"success": provider_set_membership_status(verify_id_token(_token(authorization)), req.workspace_id, req.target_uid, req.status)}
        return {"success": set_membership_status(
            req.workspace_id, req.target_uid, req.status, _token(authorization)
        )}
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))

class WorkingCopyRequest(BaseModel):
    workspace_id: str
    dataset_id: str
    working_copy_id: str | None = None
    source_version: str | None = None

@router.post("/working-copies")
def working_copy_create(req: WorkingCopyRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import create_working_copy as provider_create_working_copy
            return provider_create_working_copy(verify_id_token(_token(authorization)), req.workspace_id, req.dataset_id, req.working_copy_id, req.source_version)
        return create_working_copy(
            req.workspace_id,
            req.dataset_id,
            _token(authorization),
            req.working_copy_id,
            req.source_version,
        )
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

class ApprovedEmployee(BaseModel):
    workspace_id: str
    target_uid: str
    employee_id: str

class DelegationRequest(BaseModel):
    workspace_id: str
    team_lead_uid: str
    member_ids: list[str]
    dataset_ids: list[str]
    permissions: list[str]
    expires_at: int | None = None

@router.post("/approved-employees")
def approved_employee(req: ApprovedEmployee, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import set_approved_employee as provider_set_approved_employee
            return {"success": provider_set_approved_employee(
                require_email_verified(verify_id_token(_token(authorization))),
                req.workspace_id, req.target_uid, req.employee_id,
            )}
        return {"success": set_approved_employee(
            req.workspace_id, req.target_uid, req.employee_id, _token(authorization)
        )}
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

@router.post("/delegations")
def delegation(req: DelegationRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import set_delegation as provider_set_delegation
            return provider_set_delegation(
                require_email_verified(verify_id_token(_token(authorization))),
                req.workspace_id, req.team_lead_uid, req.member_ids, req.dataset_ids,
                req.permissions, req.expires_at,
            )
        return set_delegation(
            req.workspace_id,
            req.team_lead_uid,
            req.member_ids,
            req.dataset_ids,
            req.permissions,
            req.expires_at,
            _token(authorization),
        )
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

class DatasetRegistration(BaseModel):
    workspace_id: str
    dataset_id: str | None = None
    owner_uid: str
    protected_original: bool = True

class DatasetGrant(BaseModel):
    workspace_id: str
    dataset_id: str
    target_uid: str
    permissions: list[str]

@router.post("/datasets/register")
def dataset_register(req: DatasetRegistration, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import register_dataset as provider_register_dataset
            return provider_register_dataset(verify_id_token(_token(authorization)), req.workspace_id, req.dataset_id, req.owner_uid, req.protected_original)
        return register_dataset(
            req.workspace_id,
            req.dataset_id,
            req.owner_uid,
            _token(authorization),
            req.protected_original,
        )
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

@router.post("/datasets/grants")
def dataset_grant(req: DatasetGrant, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import set_dataset_grant
            return {"success": set_dataset_grant(verify_id_token(_token(authorization)), req.workspace_id, req.dataset_id, req.target_uid, req.permissions)}
        return {"success": set_dataset_grant(
            req.workspace_id,
            req.dataset_id,
            req.target_uid,
            req.permissions,
            _token(authorization),
        )}
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

class ResourceGrant(BaseModel):
    workspace_id: str
    resource_id: str
    target_uid: str
    permissions: list[str]

@router.post("/roles")
def role_upsert(req: RoleUpsert, authorization: str=Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import upsert_role as provider_upsert_role
            return {"success": provider_upsert_role(verify_id_token(_token(authorization)), req.workspace_id, req.role_id, req.name, req.permissions)}
        return {"success": upsert_role(req.workspace_id, req.role_id, req.name, req.permissions, _token(authorization))}
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))

@router.post("/resource-grants")
def resource_grant(req: ResourceGrant, authorization: str=Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import set_resource_grant
            return {"success": set_resource_grant(verify_id_token(_token(authorization)), req.workspace_id, req.resource_id, req.target_uid, req.permissions)}
        return {"success": set_resource_grant(req.workspace_id, req.resource_id, req.target_uid, req.permissions, _token(authorization))}
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))


class AccountCleanupRequest(BaseModel):
    uid: str

@router.post("/account/cleanup")
def account_cleanup(req: AccountCleanupRequest, authorization: str = Header(default=None)):
    try:
        if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase").strip().lower() == "supabase":
            from .supabase_provider import cleanup_account as provider_cleanup_account
            claims = require_email_verified(verify_id_token(_token(authorization)))
            return provider_cleanup_account(claims, req.uid)
        return cleanup_account(req.uid, _token(authorization))
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))


class OrganizationWorkspaceRequest(BaseModel):
    workspace_id: str

class LocationCreateRequest(OrganizationWorkspaceRequest):
    name: str

class LocationUpdateRequest(OrganizationWorkspaceRequest):
    name: str | None = None
    status: str | None = None

class SectionCreateRequest(OrganizationWorkspaceRequest):
    name: str
    location_id: str

class SectionUpdateRequest(OrganizationWorkspaceRequest):
    name: str | None = None
    status: str | None = None

class OrganizationalAssignmentCreateRequest(OrganizationWorkspaceRequest):
    principal_id: str
    role_id: str
    location_id: str | None = None
    section_id: str | None = None
    reports_to_assignment_id: str | None = None

class OrganizationalAssignmentStatusRequest(OrganizationWorkspaceRequest):
    status: str

def _organization_error(exc):
    if isinstance(exc, AuthenticationRequired): return HTTPException(401,str(exc))
    if isinstance(exc,AuthzError): return HTTPException(403,str(exc))
    if isinstance(exc,ValueError): return HTTPException(400,str(exc))
    raise exc

def _require_structure_provider():
    if os.environ.get("AUTHZ_PERSISTENCE_PROVIDER","firebase").strip().lower()!="supabase":
        raise AuthzError("Organizational structure requires the Supabase persistence provider.")

@router.get("/organizations/locations")
def organization_locations(workspace_id:str,include_inactive:bool=False,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return list_locations(verify_id_token(_token(authorization)),workspace_id,include_inactive)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.post("/organizations/locations")
def organization_location_create(req:LocationCreateRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return create_location(verify_id_token(_token(authorization)),req.workspace_id,req.name)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.patch("/organizations/locations/{location_id}")
def organization_location_update(location_id:str,req:LocationUpdateRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return update_location(verify_id_token(_token(authorization)),req.workspace_id,location_id,req.name,req.status)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.get("/organizations/sections")
def organization_sections(workspace_id:str,location_id:str|None=None,include_inactive:bool=False,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return list_sections(verify_id_token(_token(authorization)),workspace_id,include_inactive,location_id)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.post("/organizations/sections")
def organization_section_create(req:SectionCreateRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return create_section(verify_id_token(_token(authorization)),req.workspace_id,req.name,req.location_id)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.patch("/organizations/sections/{section_id}")
def organization_section_update(section_id:str,req:SectionUpdateRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return update_section(verify_id_token(_token(authorization)),req.workspace_id,section_id,req.name,req.status)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.get("/organizations/assignments")
def organization_assignments(workspace_id:str,include_inactive:bool=False,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return list_assignments(verify_id_token(_token(authorization)),workspace_id,include_inactive)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.post("/organizations/assignments")
def organization_assignment_create(req:OrganizationalAssignmentCreateRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return create_assignment(verify_id_token(_token(authorization)),req.workspace_id,req.principal_id,req.role_id,req.location_id,req.section_id,req.reports_to_assignment_id)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)

@router.patch("/organizations/assignments/{assignment_id}")
def organization_assignment_status(assignment_id:str,req:OrganizationalAssignmentStatusRequest,authorization:str=Header(default=None)):
    try:
        _require_structure_provider()
        return update_assignment_status(verify_id_token(_token(authorization)),req.workspace_id,assignment_id,req.status)
    except (AuthenticationRequired,AuthzError,ValueError) as exc: raise _organization_error(exc)
