from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel
from .service import AuthzError, AuthenticationRequired, BootstrapDenied, bootstrap_owner, mutate_role, protected_context, verify_id_token, _user

router=APIRouter(prefix="/v1/authz",tags=["authorization"])

class BootstrapRequest(BaseModel):
    id_token:str
    bootstrap_secret:str
    workspace_id:str
    expected_uid:str

class RoleMutation(BaseModel):
    target_uid:str
    role_id:str
    enabled:bool
    workspace_id:str

def _token(value):
    if not value or not value.startswith("Bearer "): raise HTTPException(401,"Firebase authentication required.")
    return value[7:].strip()

@router.get("/me")
def me(authorization: str=Header(default=None)):
    try:
        claims=verify_id_token(_token(authorization)); uid=str(claims["uid"]); user=_user(uid)
        return {"uid":uid,"email":claims.get("email"),"suspended":False,"roles":user.get("roles") or {}}
    except AuthenticationRequired as exc: raise HTTPException(401,str(exc))
    except AuthzError as exc: raise HTTPException(403,str(exc))

@router.post("/bootstrap-owner")
def bootstrap(req:BootstrapRequest):
    try:return bootstrap_owner(req.id_token,req.bootstrap_secret,req.workspace_id,req.expected_uid)
    except (BootstrapDenied,AuthenticationRequired) as exc: raise HTTPException(403,str(exc))

@router.post("/roles/mutate")
def role_mutation(req:RoleMutation,authorization: str=Header(default=None)):
    try:return {"success":mutate_role(req.target_uid,req.role_id,req.enabled,_token(authorization),req.workspace_id)}
    except AuthenticationRequired as exc: raise HTTPException(401,str(exc))
    except AuthzError as exc: raise HTTPException(403,str(exc))
