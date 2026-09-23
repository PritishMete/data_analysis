from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel
from .service import AuthzError, AuthenticationRequired, BootstrapDenied, bootstrap_owner, mutate_role, upsert_role, set_resource_grant, protected_context, verify_id_token, require_email_verified, authorization as authorize_workspace, authorize_dataset, register_dataset, set_dataset_grant, create_working_copy, authorize_working_copy, create_invitation, accept_invitation, set_membership_status, set_approved_employee, set_delegation, _user, workspace_memberships, authentication_context

router=APIRouter(prefix="/v1/authz",tags=["authorization"])

class BootstrapRequest(BaseModel):
    id_token:str
    bootstrap_secret:str
    workspace_id:str
    expected_uid:str

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

@router.get("/me")
def me(
    authorization: str = Header(default=None),
    workspace_id: str | None = Header(default=None, alias="X-InsightFlow-Workspace-ID"),
):
    try:
        claims = verify_id_token(_token(authorization))
        uid = str(claims["uid"])
        context = authentication_context(
            uid,
            workspace_id.strip() if workspace_id else None,
            bool(claims.get("email_verified")),
        )
        return {"uid": uid, "email": claims.get("email"), **context}
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
def bootstrap(req:BootstrapRequest):
    try:return bootstrap_owner(req.id_token,req.bootstrap_secret,req.workspace_id,req.expected_uid)
    except (BootstrapDenied,AuthenticationRequired) as exc: raise HTTPException(403,str(exc))

@router.post("/check")
def authorization_check(req: AuthorizationCheck, authorization: str = Header(default=None)):
    try:
        token = _token(authorization)
        claims = require_email_verified(verify_id_token(token))
        return authorize_workspace(str(claims["uid"]), req.workspace_id, req.action, req.resource_id)
    except AuthenticationRequired as exc:
        raise HTTPException(401, str(exc))
    except AuthzError as exc:
        raise HTTPException(403, str(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))

@router.post("/roles/mutate")
def role_mutation(req:RoleMutation,authorization: str=Header(default=None)):
    try:return {"success":mutate_role(req.target_uid,req.role_id,req.enabled,_token(authorization),req.workspace_id)}
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
        return accept_invitation(req.workspace_id, req.invitation_id, _token(authorization))
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))

@router.post("/membership/status")
def membership_status(req: MembershipStatusRequest, authorization: str = Header(default=None)):
    try:
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
    dataset_id: str
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
        return {"success": upsert_role(req.workspace_id, req.role_id, req.name, req.permissions, _token(authorization))}
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))

@router.post("/resource-grants")
def resource_grant(req: ResourceGrant, authorization: str=Header(default=None)):
    try:
        return {"success": set_resource_grant(req.workspace_id, req.resource_id, req.target_uid, req.permissions, _token(authorization))}
    except AuthenticationRequired as exc: raise HTTPException(401, str(exc))
    except AuthzError as exc: raise HTTPException(403, str(exc))
    except ValueError as exc: raise HTTPException(400, str(exc))
