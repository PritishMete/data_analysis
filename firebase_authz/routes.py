from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel
from .service import *

router=APIRouter(prefix="/v1/authz", tags=["authorization"])

class BootstrapRequest(BaseModel):
    id_token:str; bootstrap_secret:str; workspace_id:str; expected_uid:str
class RoleMutation(BaseModel):
    target_uid:str; role_id:str; enabled:bool

def _token(auth_header):
    if not auth_header or not auth_header.startswith("Bearer "): raise HTTPException(401,"Firebase authentication required.")
    return auth_header[7:].strip()

@router.get("/me")
def me(authorization_header: str = Header(default=None, alias="Authorization")):
    token=_token(authorization_header); claims=verify_id_token(token); uid=str(claims["uid"])
    user=_user(uid)
    return {"uid":uid,"email":claims.get("email"),"suspended":False,"roles":user.get("roles") or {}}

@router.post("/bootstrap-owner")
def bootstrap(req:BootstrapRequest):
    try:return bootstrap_owner(req.id_token,req.bootstrap_secret,req.workspace_id,req.expected_uid)
    except AuthzError as exc: raise HTTPException(403,str(exc))

@router.post("/roles/mutate")
def role_mutation(req:RoleMutation, authorization_header: str = Header(default=None, alias="Authorization")):
    try:return {"success":mutate_role(req.target_uid,req.role_id,req.enabled,_token(authorization_header))}
    except AuthzError as exc: raise HTTPException(403,str(exc))
