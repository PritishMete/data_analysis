from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import text

from core.db import SessionLocal
from firebase_authz.service import PermissionDenied
from firebase_authz.supabase_provider import _identity
from .service import _authorization_context, _claims


def _branch_head_context(token: str, workspace_id: str) -> tuple[dict[str, Any], str, str]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    if "branch_head" not in set(context.get("role_ids", [])):
        raise PermissionDenied("Only a Branch Head can manage Manager upload grants.")
    provider, subject = _identity(claims)
    return context, provider, subject


def create_manager_upload_grant(
    *, workspace_id: str, token: str, manager_principal_id: str, location_id: str
) -> dict[str, Any]:
    context, provider, subject = _branch_head_context(token, workspace_id)
    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    actor = str(context["principal_id"])
    manager = str(manager_principal_id or "").strip()
    location = str(location_id or "").strip()
    if not manager or not location:
        raise ValueError("manager_principal_id and location_id are required.")
    grant_id = "mug_" + uuid.uuid4().hex
    with SessionLocal.begin() as db:
        # Lock the issuer's exact branch assignment, the target manager's branch
        # assignment, and both memberships so revocation/suspension serializes
        # with grant issuance.
        issuer = db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m ON m.organization_id=oa.organization_id
              AND m.principal_id=oa.principal_id
            JOIN member_roles mr ON mr.organization_id=oa.organization_id
              AND mr.principal_id=oa.principal_id AND mr.role_id='branch_head'
            JOIN identity_bindings ib ON ib.principal_id=m.principal_id
              AND ib.status='active' AND ib.provider=:provider
              AND ib.provider_subject=:subject
            JOIN locations l ON l.organization_id=oa.organization_id
              AND l.location_id=oa.location_id AND l.status='active'
            WHERE oa.organization_id=:org AND oa.principal_id=:actor
              AND oa.location_id=:location AND oa.role_id='branch_head'
              AND oa.status='active' AND m.workspace_id=:workspace AND m.status='active'
            LIMIT 1 FOR SHARE OF oa, m, mr, ib, l
        """), {"org": org, "workspace": workspace, "actor": actor,
                "location": location, "provider": provider, "subject": subject}).scalar_one_or_none()
        if issuer is None:
            raise PermissionDenied("An active Branch Head assignment to this branch is required.")
        target = db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m ON m.organization_id=oa.organization_id
              AND m.principal_id=oa.principal_id
            JOIN member_roles mr ON mr.organization_id=oa.organization_id
              AND mr.principal_id=oa.principal_id AND mr.role_id='manager'
            JOIN locations l ON l.organization_id=oa.organization_id
              AND l.location_id=oa.location_id AND l.status='active'
            WHERE oa.organization_id=:org AND m.workspace_id=:workspace
              AND oa.principal_id=:manager AND oa.location_id=:location
              AND oa.role_id='manager' AND oa.status='active' AND m.status='active'
            LIMIT 1 FOR SHARE OF oa, m, mr, l
        """), {"org": org, "workspace": workspace, "manager": manager,
                "location": location}).scalar_one_or_none()
        if target is None:
            raise ValueError("The selected Manager must have an active assignment to this exact branch.")
        existing = db.execute(text("""
            SELECT grant_id FROM manager_dataset_upload_grants
            WHERE organization_id=:org AND workspace_id=:workspace
              AND manager_principal_id=:manager AND location_id=:location
              AND revoked_at IS NULL
            FOR UPDATE
        """), {"org": org, "workspace": workspace, "manager": manager,
                "location": location}).scalar_one_or_none()
        if existing:
            return {"grant_id": str(existing), "status": "active",
                    "manager_principal_id": manager, "location_id": location}
        db.execute(text("""
            INSERT INTO manager_dataset_upload_grants
              (grant_id, organization_id, workspace_id, manager_principal_id,
               location_id, granted_by_principal_id)
            VALUES (:grant, :org, :workspace, :manager, :location, :actor)
        """), {"grant": grant_id, "org": org, "workspace": workspace,
                "manager": manager, "location": location, "actor": actor})
        db.execute(text("""
            INSERT INTO audit_events
              (event_id, organization_id, actor_principal_id, action, outcome, metadata)
            VALUES (:event, :org, :actor, 'dataset.upload_grant.create', 'succeeded',
                    CAST(:metadata AS jsonb))
        """), {"event": "evt_" + uuid.uuid4().hex, "org": org, "actor": actor,
                "metadata": __import__("json").dumps({
                    "grant_id": grant_id, "manager_principal_id": manager,
                    "location_id": location,
                })})
    return {"grant_id": grant_id, "status": "active",
            "manager_principal_id": manager, "location_id": location}


def revoke_manager_upload_grant(
    *, workspace_id: str, token: str, grant_id: str, reason: str | None = None
) -> dict[str, Any]:
    context, provider, subject = _branch_head_context(token, workspace_id)
    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    actor = str(context["principal_id"])
    note = (reason or "").strip()
    if len(note) > 1000:
        raise ValueError("Revocation reason must be at most 1000 characters.")
    with SessionLocal.begin() as db:
        grant = db.execute(text("""
            SELECT * FROM manager_dataset_upload_grants
            WHERE grant_id=:grant AND organization_id=:org AND workspace_id=:workspace
            FOR UPDATE
        """), {"grant": grant_id, "org": org, "workspace": workspace}).mappings().first()
        if grant is None:
            raise FileNotFoundError("Manager upload grant not found.")
        issuer = db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m ON m.organization_id=oa.organization_id
              AND m.principal_id=oa.principal_id
            JOIN member_roles mr ON mr.organization_id=oa.organization_id
              AND mr.principal_id=oa.principal_id AND mr.role_id='branch_head'
            JOIN identity_bindings ib ON ib.principal_id=m.principal_id
              AND ib.status='active' AND ib.provider=:provider
              AND ib.provider_subject=:subject
            WHERE oa.organization_id=:org AND m.workspace_id=:workspace
              AND oa.principal_id=:actor AND oa.location_id=:location
              AND oa.role_id='branch_head' AND oa.status='active' AND m.status='active'
            LIMIT 1 FOR SHARE OF oa, m, mr, ib
        """), {"org": org, "workspace": workspace, "actor": actor,
                "location": grant["location_id"], "provider": provider,
                "subject": subject}).scalar_one_or_none()
        if issuer is None:
            raise PermissionDenied("An active Branch Head assignment to the grant's branch is required.")
        if grant["revoked_at"] is None:
            db.execute(text("""
                UPDATE manager_dataset_upload_grants
                SET revoked_at=now(), revoked_by_principal_id=:actor, revoke_reason=:reason
                WHERE grant_id=:grant AND revoked_at IS NULL
            """), {"actor": actor, "reason": note or None, "grant": grant_id})
            db.execute(text("""
                INSERT INTO audit_events
                  (event_id, organization_id, actor_principal_id, action, outcome, metadata)
                VALUES (:event, :org, :actor, 'dataset.upload_grant.revoke', 'succeeded',
                        CAST(:metadata AS jsonb))
            """), {"event": "evt_" + uuid.uuid4().hex, "org": org, "actor": actor,
                    "metadata": __import__("json").dumps({
                        "grant_id": grant_id, "location_id": grant["location_id"],
                        "reason": note or None,
                    })})
    # Run proposal invalidation after releasing the grant lock. Approval locks a
    # proposal and then the grant; this two-transaction sequence avoids a
    # grant->proposal / proposal->grant deadlock while still blocking approvals.
    with SessionLocal.begin() as db:
        db.execute(text("""
            UPDATE dataset_change_proposals
            SET status='stale', reviewed_at=now(),
                decision_note='Manager upload grant was revoked before review.'
            WHERE upload_grant_id=:grant AND status='pending'
        """), {"grant": grant_id})
    return {"grant_id": grant_id, "status": "revoked",
            "location_id": str(grant["location_id"])}



def list_manager_upload_grants(
    *, workspace_id: str, token: str, location_id: str | None = None
) -> list[dict[str, Any]]:
    context, provider, subject = _branch_head_context(token, workspace_id)
    org = str(context["organization_id"])
    workspace = str(context["workspace_id"])
    actor = str(context["principal_id"])
    location = str(location_id or "").strip()
    if not location:
        raise ValueError("location_id is required to list branch-scoped grants.")
    with SessionLocal.begin() as db:
        active = db.execute(text("""
            SELECT oa.assignment_id
            FROM organizational_assignments oa
            JOIN organization_members m ON m.organization_id=oa.organization_id
              AND m.principal_id=oa.principal_id
            JOIN member_roles mr ON mr.organization_id=oa.organization_id
              AND mr.principal_id=oa.principal_id AND mr.role_id='branch_head'
            JOIN identity_bindings ib ON ib.principal_id=m.principal_id
              AND ib.status='active' AND ib.provider=:provider
              AND ib.provider_subject=:subject
            JOIN locations l ON l.organization_id=oa.organization_id
              AND l.location_id=oa.location_id AND l.status='active'
            WHERE oa.organization_id=:org AND m.workspace_id=:workspace
              AND oa.principal_id=:actor AND oa.location_id=:location
              AND oa.role_id='branch_head' AND oa.status='active' AND m.status='active'
            LIMIT 1 FOR SHARE OF oa, m, mr, ib, l
        """), {"org": org, "workspace": workspace, "actor": actor,
                "location": location, "provider": provider, "subject": subject}).scalar_one_or_none()
        if active is None:
            raise PermissionDenied("An active Branch Head assignment to this branch is required.")
        rows = db.execute(text("""
            SELECT g.grant_id, g.manager_principal_id, g.location_id,
                   g.granted_by_principal_id, g.granted_at, g.revoked_by_principal_id,
                   g.revoked_at, g.revoke_reason
            FROM manager_dataset_upload_grants g
            WHERE g.organization_id=:org AND g.workspace_id=:workspace
              AND g.location_id=:location
            ORDER BY g.granted_at DESC, g.grant_id
        """), {"org": org, "workspace": workspace, "location": location}).mappings().all()
        return [{
            "grant_id": str(row["grant_id"]),
            "manager_principal_id": str(row["manager_principal_id"]),
            "location_id": str(row["location_id"]),
            "granted_by_principal_id": str(row["granted_by_principal_id"]),
            "granted_at": row["granted_at"].isoformat() if row["granted_at"] else None,
            "revoked_by_principal_id": row["revoked_by_principal_id"],
            "revoked_at": row["revoked_at"].isoformat() if row["revoked_at"] else None,
            "revoke_reason": row["revoke_reason"],
            "status": "revoked" if row["revoked_at"] else "active",
        } for row in rows]
