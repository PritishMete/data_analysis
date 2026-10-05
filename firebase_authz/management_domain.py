"""Business-facing management domain operations.

This module is additive to the existing authorization provider. It reuses
organizations, locations, sections, organizational_assignments, memberships,
roles, and audit_events rather than introducing a second hierarchy or RBAC
model.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import text

from core.db import SessionLocal
from .schema import ROLE_LEVELS
from .service import AuthzError


class ManagementConflict(AuthzError):
    """A valid management request conflicts with current organizational state."""


def _id(prefix: str) -> str:
    import uuid
    return f"{prefix}_{uuid.uuid4().hex}"


def _identity(claims: dict[str, Any]) -> tuple[str, str]:
    uid = str(claims.get("uid") or claims.get("sub") or "").strip()
    provider = str(claims.get("provider") or "").strip().lower()
    if provider:
        return provider, str(claims.get("sub") or uid)
    firebase = claims.get("firebase") if isinstance(claims.get("firebase"), dict) else {}
    provider = str(firebase.get("sign_in_provider") or "firebase").strip().lower()
    identities = firebase.get("identities") if isinstance(firebase.get("identities"), dict) else {}
    values = identities.get(provider)
    subject = str(values[0]) if isinstance(values, list) and values else str(claims.get("sub") or uid)
    return provider, subject


def _actor(db, claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    provider, subject = _identity(claims)
    row = db.execute(text("""
        SELECT p.principal_id, m.employee_id, m.status, o.organization_id, o.name AS organization_name
        FROM identity_bindings b
        JOIN principals p ON p.principal_id=b.principal_id
        JOIN organization_members m ON m.principal_id=p.principal_id
        JOIN organizations o ON o.organization_id=m.organization_id
        WHERE b.provider=:provider AND b.provider_subject=:subject
          AND m.workspace_id=:workspace
          AND b.status='active'
    """), {"provider": provider, "subject": subject, "workspace": workspace_id}).mappings().first()
    if not row or row["status"] != "active":
        raise AuthzError("Workspace authorization denied.")
    return dict(row)


def _permissions(db, organization_id: str, principal_id: str) -> set[str]:
    return set(db.execute(text("""
        SELECT DISTINCT rp.permission_id
        FROM member_roles mr
        JOIN role_permissions rp ON rp.role_id=mr.role_id
        WHERE mr.organization_id=:org AND mr.principal_id=:principal
    """), {"org": organization_id, "principal": principal_id}).scalars().all())


def _is_org_manager(db, organization_id: str, principal_id: str, location_id: str) -> bool:
    return db.execute(text("""
        SELECT 1
        FROM organizational_assignments
        WHERE organization_id=:org AND principal_id=:principal
          AND location_id=:location AND role_id='manager' AND status='active'
        LIMIT 1
    """), {"org": organization_id, "principal": principal_id, "location": location_id}).scalar_one_or_none() is not None


def _require_read(db, actor: dict[str, Any]) -> None:
    if "organization.view" not in _permissions(db, actor["organization_id"], actor["principal_id"]):
        raise AuthzError("Workspace authorization denied.")


def _management_scope(db, actor: dict[str, Any]) -> dict[str, Any]:
    """Resolve the actor's authoritative organizational assignment scope.

    Multiple active assignments remain separate contexts for one principal.
    Team Lead scope therefore aggregates all of that principal's active
    section assignments instead of collapsing them to one section.
    """
    rows = db.execute(text("""
        SELECT assignment_id, location_id, section_id, role_id
        FROM organizational_assignments
        WHERE organization_id=:org
          AND principal_id=:principal
          AND status='active'
    """), {
        "org": actor["organization_id"],
        "principal": actor["principal_id"],
    }).mappings().all()
    if not rows:
        return {
            "role_id": None,
            "location_id": None,
            "location_ids": [],
            "section_id": None,
            "section_ids": [],
            "organization_wide": False,
        }

    role_id = max(
        (str(row["role_id"]) for row in rows),
        key=lambda value: ROLE_LEVELS.get(value, 0),
    )
    if role_id == "organization_owner":
        return {
            "role_id": role_id,
            "location_id": None,
            "location_ids": [],
            "section_id": None,
            "section_ids": [],
            "organization_wide": True,
        }

    scoped = [row for row in rows if str(row["role_id"]) == role_id]
    location_ids = list(dict.fromkeys(
        str(row["location_id"]) for row in scoped if row["location_id"] is not None
    ))
    section_ids = list(dict.fromkeys(
        str(row["section_id"]) for row in scoped if row["section_id"] is not None
    ))
    return {
        "role_id": role_id,
        "location_id": location_ids[0] if len(location_ids) == 1 else None,
        "location_ids": location_ids,
        "section_id": section_ids[0] if len(section_ids) == 1 else None,
        "section_ids": section_ids,
        "organization_wide": False,
    }


def _require_location_manage(db, actor: dict[str, Any], location_id: str) -> None:
    permissions = _permissions(db, actor["organization_id"], actor["principal_id"])
    scope = _management_scope(db, actor)
    if scope["organization_wide"] and "organization.manage" in permissions:
        return
    if scope["role_id"] == "branch_head" and "organization.manage" in permissions:
        if scope["location_id"] and str(scope["location_id"]) == str(location_id):
            return
    if scope["role_id"] == "manager" and "users.manage" in permissions:
        if (
            scope["location_id"]
            and str(scope["location_id"]) == str(location_id)
            and _is_org_manager(
                db, actor["organization_id"], actor["principal_id"], location_id
            )
        ):
            return
    raise AuthzError("You don't have permission to manage this location.")


def _read_scope(db, actor: dict[str, Any]) -> dict[str, Any]:
    return _management_scope(db, actor)


def _scope_location_ids(scope: dict[str, Any], locations: list[Any]) -> list[Any]:
    if scope["organization_wide"]:
        return locations
    location_ids = {str(value) for value in scope.get("location_ids", [])}
    return [value for value in locations if str(value) in location_ids]


def _location(db, organization_id: str, location_id: str) -> dict[str, Any]:
    row = db.execute(text("""
        SELECT location_id, organization_id, name, branch_identifier, status
        FROM locations
        WHERE organization_id=:org AND location_id=:location
    """), {"org": organization_id, "location": location_id}).mappings().first()
    if not row:
        raise AuthzError("Location is not part of your organization.")
    return dict(row)


def _section(db, organization_id: str, section_id: str) -> dict[str, Any]:
    row = db.execute(text("""
        SELECT section_id, organization_id, location_id, name, status
        FROM sections
        WHERE organization_id=:org AND section_id=:section
    """), {"org": organization_id, "section": section_id}).mappings().first()
    if not row:
        raise AuthzError("Section is not part of your organization.")
    return dict(row)


def _member_principal(db, organization_id: str, principal_id: str) -> dict[str, Any]:
    row = db.execute(text("""
        SELECT m.principal_id, m.employee_id, m.status
        FROM organization_members m
        WHERE m.organization_id=:org AND m.principal_id=:principal
    """), {"org": organization_id, "principal": principal_id}).mappings().first()
    if not row or row["status"] != "active":
        raise AuthzError("Candidate is not an active organization member.")
    return dict(row)


def _assignment(db, organization_id: str, assignment_id: str) -> dict[str, Any]:
    row = db.execute(text("""
        SELECT oa.assignment_id, oa.organization_id, oa.principal_id, m.employee_id,
               oa.location_id, oa.role_id, oa.section_id, oa.reports_to_assignment_id,
               oa.status
        FROM organizational_assignments oa
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        WHERE oa.organization_id=:org AND oa.assignment_id=:assignment
    """), {"org": organization_id, "assignment": assignment_id}).mappings().first()
    if not row:
        raise AuthzError("Organizational assignment is not part of your organization.")
    return dict(row)


def _profile_summary_sql(alias: str = "profile") -> str:
    return f"""
        {alias}.full_name,
        {alias}.email_verified_at IS NOT NULL AS email_verified,
        {alias}.phone_verified_at IS NOT NULL AS phone_verified,
        ({alias}.id_proof_number IS NOT NULL AND {alias}.id_proof_number <> '') AS id_proof_supplied,
        (
            CASE WHEN coalesce({alias}.full_name, '') <> '' THEN 1 ELSE 0 END
            + CASE WHEN coalesce({alias}.email, '') <> ''
                        AND {alias}.email_verified_at IS NOT NULL THEN 1 ELSE 0 END
            + CASE WHEN coalesce({alias}.phone_e164, '') <> ''
                        AND {alias}.phone_verified_at IS NOT NULL THEN 1 ELSE 0 END
            + CASE
                WHEN coalesce({alias}.address_line1, '') <> ''
                 AND coalesce({alias}.state, '') <> ''
                 AND coalesce({alias}.postal_code, '') <> ''
                 AND coalesce({alias}.country, '') <> ''
                THEN 1 ELSE 0 END
            + CASE
                WHEN coalesce({alias}.id_proof_type, '') <> ''
                 AND coalesce({alias}.id_proof_number, '') <> ''
                THEN 1 ELSE 0 END
        ) * 20 AS profile_completeness_percent
    """


def _require_sensitive_profile_read(db, actor: dict[str, Any]) -> None:
    if "users.manage" not in _permissions(
        db, actor["organization_id"], actor["principal_id"]
    ):
        raise AuthzError("You don't have permission to view sensitive employee profile details.")


def _profile_detail(db, organization_id: str, assignment_id: str) -> dict[str, Any]:
    row = db.execute(text(f"""
        SELECT oa.assignment_id, oa.organization_id, oa.principal_id,
               m.employee_id, oa.role_id, oa.location_id, l.name AS location_name,
               oa.section_id, s.name AS section_name, oa.status,
               oa.reports_to_assignment_id,
               parent_member.employee_id AS reports_to_employee_id,
               parent.role_id AS reports_to_role_id,
               profile.full_name, profile.email, profile.email_verified_at,
               profile.phone_e164, profile.phone_verified_at,
               profile.address_line1, profile.address_line2,
               profile.state, profile.postal_code, profile.country,
               profile.id_proof_type, profile.id_proof_number,
               profile.id_proof_provided_at, profile.created_at AS profile_created_at,
               profile.updated_at AS profile_updated_at,
               oa.created_at AS assignment_created_at,
               oa.updated_at AS assignment_updated_at,
               {_profile_summary_sql("profile")}
        FROM organizational_assignments oa
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        LEFT JOIN locations l
          ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
        LEFT JOIN sections s
          ON s.organization_id=oa.organization_id AND s.section_id=oa.section_id
        LEFT JOIN organizational_assignments parent
          ON parent.assignment_id=oa.reports_to_assignment_id
        LEFT JOIN organization_members parent_member
          ON parent_member.organization_id=parent.organization_id
         AND parent_member.principal_id=parent.principal_id
        LEFT JOIN organization_member_profiles profile
          ON profile.organization_id=m.organization_id
         AND profile.principal_id=m.principal_id
        WHERE oa.organization_id=:org AND oa.assignment_id=:assignment
    """), {"org": organization_id, "assignment": assignment_id}).mappings().first()
    if not row:
        raise AuthzError("Organizational assignment is not part of your organization.")
    return dict(row)


def _audit(db, organization_id: str, actor_principal_id: str, action: str,
           outcome: str, metadata: dict[str, Any]) -> None:
    import json
    db.execute(text("""
        INSERT INTO audit_events
          (event_id, organization_id, actor_principal_id, action, outcome, metadata)
        VALUES (:event, :org, :actor, :action, :outcome, CAST(:metadata AS jsonb))
    """), {
        "event": _id("evt"),
        "org": organization_id,
        "actor": actor_principal_id,
        "action": action,
        "outcome": outcome,
        "metadata": json.dumps(metadata),
    })


def _role_counts(db, organization_id: str, location_id: str | None = None) -> dict[str, int]:
    params = {"org": organization_id, "location": location_id}
    location_clause = "AND oa.location_id=:location" if location_id else ""
    rows = db.execute(text(f"""
        SELECT oa.role_id, count(DISTINCT oa.principal_id) AS count
        FROM organizational_assignments oa
        WHERE oa.organization_id=:org AND oa.status='active' {location_clause}
        GROUP BY oa.role_id
    """), params).all()
    return {str(row.role_id): int(row.count) for row in rows}


def _location_summary(db, organization_id: str, location_id: str) -> dict[str, Any]:
    location = _location(db, organization_id, location_id)
    manager = db.execute(text("""
        SELECT oa.assignment_id, oa.principal_id, m.employee_id,
               profile.full_name
        FROM organizational_assignments oa
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        LEFT JOIN organization_member_profiles profile
          ON profile.organization_id=m.organization_id
         AND profile.principal_id=m.principal_id
        WHERE oa.organization_id=:org AND oa.location_id=:location
          AND oa.role_id='manager' AND oa.status='active'
        LIMIT 1
    """), {"org": organization_id, "location": location_id}).mappings().first()
    branch_head = db.execute(text("""
        SELECT oa.assignment_id, oa.principal_id, m.employee_id,
               profile.full_name
        FROM organizational_assignments oa
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        LEFT JOIN organization_member_profiles profile
          ON profile.organization_id=m.organization_id
         AND profile.principal_id=m.principal_id
        WHERE oa.organization_id=:org AND oa.location_id=:location
          AND oa.role_id='branch_head' AND oa.status='active'
        ORDER BY oa.created_at, oa.assignment_id
        LIMIT 1
    """), {"org": organization_id, "location": location_id}).mappings().first()
    counts = _role_counts(db, organization_id, location_id)
    section_count = db.execute(text("""
        SELECT count(*) FROM sections
        WHERE organization_id=:org AND location_id=:location AND status='active'
    """), {"org": organization_id, "location": location_id}).scalar_one()
    return {
        **location,
        "branch_head": dict(branch_head) if branch_head else None,
        "manager": dict(manager) if manager else None,
        "employee_count": counts.get("employee", 0),
        "team_lead_count": counts.get("team_lead", 0),
        "section_count": int(section_count),
    }

def _management_ui_policy(role_id: str | None) -> dict[str, Any]:
    role = str(role_id or "").strip()
    if role in {"organization_owner", "branch_head"}:
        sections = [
            "overview", "organization", "people",
            "dataAccess", "invitations", "audit",
        ]
    elif role == "manager":
        # Managers can manage their branch/team scope, request working-copy
        # access, and request Team Lead assignments. They do not administer
        # invitations; invitation administration stays with Branch Head /
        # Organization Owner.
        sections = ["overview", "people", "dataAccess"]
    elif role == "team_lead":
        sections = ["overview", "people", "dataAccess"]
    else:
        sections = ["overview"]
    return {"sections": sections}


def management_overview(claims: dict[str, Any], workspace_id: str) -> dict[str, Any]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_read(db, actor)
        org = actor["organization_id"]
        scope = _read_scope(db, actor)
        locations = db.execute(text("""
            SELECT location_id FROM locations
            WHERE organization_id=:org
            ORDER BY lower(name), location_id
        """), {"org": org}).scalars().all()
        locations = _scope_location_ids(scope, locations)
        if scope["organization_wide"]:
            counts = _role_counts(db, org)
        else:
            scoped_locations = list(scope.get("location_ids", []))
            if not scoped_locations:
                counts = {}
            else:
                rows = db.execute(text("""
                    SELECT oa.role_id, count(DISTINCT oa.principal_id) AS count
                    FROM organizational_assignments oa
                    WHERE oa.organization_id=:org
                      AND oa.status='active'
                      AND oa.location_id = ANY(:locations)
                    GROUP BY oa.role_id
                """), {"org": org, "locations": scoped_locations}).all()
                counts = {str(row.role_id): int(row.count) for row in rows}
        return {
            "organization": {
                "organization_id": org,
                "name": actor["organization_name"],
                "status": db.execute(
                    text("SELECT status FROM organizations WHERE organization_id=:org"),
                    {"org": org},
                ).scalar_one(),
            },
            "actor": {
                "principal_id": actor["principal_id"],
                "employee_id": actor["employee_id"],
                "role_id": scope["role_id"],
                "location_id": scope["location_id"],
                "section_id": scope["section_id"],
                "organization_wide": scope["organization_wide"],
            },
            "ui_policy": _management_ui_policy(scope["role_id"]),
            "summary": {
                "location_count": len(locations),
                "total_people": sum(counts.values()),
                "branch_head_count": counts.get("branch_head", 0),
                "employee_count": counts.get("employee", 0),
                "manager_count": counts.get("manager", 0),
                "team_lead_count": counts.get("team_lead", 0),
                "role_counts": counts,
            },
            "locations": [_location_summary(db, org, str(location_id)) for location_id in locations],
        }


def list_locations(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_read(db, actor)
        scope = _read_scope(db, actor)
        ids = db.execute(text("""
            SELECT location_id FROM locations
            WHERE organization_id=:org
            ORDER BY lower(name), location_id
        """), {"org": actor["organization_id"]}).scalars().all()
        ids = _scope_location_ids(scope, ids)
        return [_location_summary(db, actor["organization_id"], str(location_id)) for location_id in ids]


def create_location(claims: dict[str, Any], workspace_id: str, name: str,
                    branch_identifier: str) -> dict[str, Any]:
    name = str(name or "").strip()
    branch_identifier = str(branch_identifier or "")
    if not 1 <= len(name) <= 160 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Location name must be between 1 and 160 characters.")
    if not branch_identifier:
        raise ValueError("Branch identifier is required.")
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        permissions = _permissions(db, actor["organization_id"], actor["principal_id"])
        scope = _management_scope(db, actor)
        if (
            not scope["organization_wide"]
            or "organization.manage" not in permissions
        ):
            raise AuthzError("You don't have permission to create locations.")
        org = actor["organization_id"]
        duplicate = db.execute(text("""
            SELECT 1 FROM locations
            WHERE status='active' AND lower(branch_identifier)=lower(:identifier)
            LIMIT 1
        """), {"identifier": branch_identifier}).scalar_one_or_none()
        if duplicate:
            raise ManagementConflict("Branch identifier is already in use by an active branch.")
        duplicate_name = db.execute(text("""
            SELECT 1 FROM locations
            WHERE organization_id=:org AND status='active' AND lower(name)=lower(:name)
            LIMIT 1
        """), {"org": org, "name": name}).scalar_one_or_none()
        if duplicate_name:
            raise ManagementConflict("An active location with this name already exists.")
        location_id = _id("loc")
        db.execute(text("""
            INSERT INTO locations(location_id, organization_id, name, branch_identifier)
            VALUES (:location, :org, :name, :identifier)
        """), {"location": location_id, "org": org, "name": name, "identifier": branch_identifier})
        _audit(db, org, actor["principal_id"], "management.location.created", "succeeded", {
            "location_id": location_id, "branch_identifier": branch_identifier,
        })
        return _location_summary(db, org, location_id)


def list_sections(claims: dict[str, Any], workspace_id: str,
                  location_id: str | None = None) -> list[dict[str, Any]]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_read(db, actor)
        org = actor["organization_id"]
        scope = _read_scope(db, actor)
        if not scope["organization_wide"]:
            scoped_locations = {str(value) for value in scope.get("location_ids", [])}
            if location_id and str(location_id) not in scoped_locations:
                raise AuthzError("Location is outside your management scope.")
            if not scoped_locations:
                return []
            if location_id is None and len(scoped_locations) == 1:
                location_id = next(iter(scoped_locations))
        if location_id:
            _location(db, org, location_id)
        if scope["organization_wide"]:
            if location_id:
                rows = db.execute(text("""
                    SELECT s.section_id, s.organization_id, s.location_id, s.name, s.status
                    FROM sections s
                    WHERE s.organization_id=:org
                      AND s.location_id=:location
                    ORDER BY lower(s.name), s.section_id
                """), {"org": org, "location": location_id}).mappings().all()
            else:
                rows = db.execute(text("""
                    SELECT s.section_id, s.organization_id, s.location_id, s.name, s.status
                    FROM sections s
                    WHERE s.organization_id=:org
                    ORDER BY lower(s.name), s.section_id
                """), {"org": org}).mappings().all()
        elif scope["role_id"] == "team_lead":
            params = {"org": org, "principal": actor["principal_id"]}
            rows = db.execute(text("""
                SELECT s.section_id, s.organization_id, s.location_id, s.name, s.status
                FROM sections s
                WHERE s.organization_id=:org
                  AND EXISTS (
                    SELECT 1
                    FROM organizational_assignments scope_oa
                    WHERE scope_oa.organization_id=s.organization_id
                      AND scope_oa.principal_id=:principal
                      AND scope_oa.status='active'
                      AND scope_oa.role_id='team_lead'
                      AND scope_oa.section_id=s.section_id
                  )
                ORDER BY lower(s.name), s.section_id
            """), params).mappings().all()
        elif scope["role_id"] in {"branch_head", "manager"}:
            params = {"org": org, "location": location_id}
            rows = db.execute(text("""
                SELECT s.section_id, s.organization_id, s.location_id, s.name, s.status
                FROM sections s
                WHERE s.organization_id=:org
                  AND s.location_id=:location
                ORDER BY lower(s.name), s.section_id
            """), params).mappings().all()
        else:
            rows = db.execute(text("""
                SELECT s.section_id, s.organization_id, s.location_id, s.name, s.status
                FROM sections s
                WHERE s.organization_id=:org
                  AND EXISTS (
                    SELECT 1
                    FROM organizational_assignments scope_oa
                    WHERE scope_oa.organization_id=s.organization_id
                      AND scope_oa.principal_id=:principal
                      AND scope_oa.status='active'
                      AND scope_oa.section_id=s.section_id
                  )
                ORDER BY lower(s.name), s.section_id
            """), {"org": org, "principal": actor["principal_id"]}).mappings().all()
        result = []
        for row in rows:
            item = dict(row)
            team_leads = db.execute(text("""
                SELECT oa.assignment_id, oa.principal_id, m.employee_id
                FROM organizational_assignments oa
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                WHERE oa.organization_id=:org AND oa.section_id=:section
                  AND oa.role_id='team_lead' AND oa.status='active'
                ORDER BY m.employee_id, oa.assignment_id
            """), {"org": org, "section": row["section_id"]}).mappings().all()
            item["team_leads"] = [dict(value) for value in team_leads]
            item["employee_count"] = int(db.execute(text("""
                SELECT count(DISTINCT principal_id) FROM organizational_assignments
                WHERE organization_id=:org AND section_id=:section
                  AND role_id='employee' AND status='active'
            """), {"org": org, "section": row["section_id"]}).scalar_one())
            result.append(item)
        return result


def create_section(claims: dict[str, Any], workspace_id: str, location_id: str,
                   name: str) -> dict[str, Any]:
    name = str(name or "").strip()
    if not 1 <= len(name) <= 160 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Section name must be between 1 and 160 characters.")
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        org = actor["organization_id"]
        _require_location_manage(db, actor, location_id)
        _location(db, org, location_id)
        duplicate = db.execute(text("""
            SELECT 1 FROM sections
            WHERE organization_id=:org AND location_id=:location
              AND lower(name)=lower(:name) AND status='active'
        """), {"org": org, "location": location_id, "name": name}).scalar_one_or_none()
        if duplicate:
            raise ManagementConflict("An active section with this name already exists.")
        section_id = _id("sec")
        db.execute(text("""
            INSERT INTO sections(section_id, organization_id, location_id, name)
            VALUES (:section, :org, :location, :name)
        """), {"section": section_id, "org": org, "location": location_id, "name": name})
        _audit(db, org, actor["principal_id"], "management.section.created", "succeeded", {
            "section_id": section_id, "location_id": location_id,
        })
        return dict(db.execute(text("""
            SELECT section_id, organization_id, location_id, name, status
            FROM sections WHERE section_id=:section
        """), {"section": section_id}).mappings().one())


def list_people(claims: dict[str, Any], workspace_id: str, search: str | None = None,
                role: str | None = None, location_id: str | None = None,
                section_id: str | None = None, status: str | None = None) -> list[dict[str, Any]]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_read(db, actor)
        org = actor["organization_id"]
        if location_id:
            _location(db, org, location_id)
        if section_id:
            section = _section(db, org, section_id)
            if location_id and section["location_id"] != location_id:
                raise AuthzError("Section does not belong to the requested location.")
        clauses = ["oa.organization_id=:org"]
        params: dict[str, Any] = {"org": org}
        scope = _read_scope(db, actor)
        if not scope["organization_wide"]:
            scoped_locations = {str(value) for value in scope.get("location_ids", [])}
            if location_id and str(location_id) not in scoped_locations:
                raise AuthzError("Location is outside your management scope.")
            if scope["role_id"] == "team_lead":
                scoped_sections = {str(value) for value in scope.get("section_ids", [])}
                if section_id and str(section_id) not in scoped_sections:
                    raise AuthzError("Section is outside your management scope.")
                clauses.append("""
                    EXISTS (
                        SELECT 1
                        FROM organizational_assignments scope_oa
                        WHERE scope_oa.organization_id=oa.organization_id
                          AND scope_oa.principal_id=:scope_principal
                          AND scope_oa.status='active'
                          AND scope_oa.role_id='team_lead'
                          AND scope_oa.location_id=oa.location_id
                          AND scope_oa.section_id=oa.section_id
                    )
                """)
                params["scope_principal"] = actor["principal_id"]
            elif scope["role_id"] in {"branch_head", "manager"}:
                clauses.append("""
                    EXISTS (
                        SELECT 1
                        FROM organizational_assignments scope_oa
                        WHERE scope_oa.organization_id=oa.organization_id
                          AND scope_oa.principal_id=:scope_principal
                          AND scope_oa.status='active'
                          AND scope_oa.role_id=:scope_role
                          AND scope_oa.location_id=oa.location_id
                    )
                """)
                params["scope_principal"] = actor["principal_id"]
                params["scope_role"] = scope["role_id"]
            else:
                clauses.append("oa.principal_id=:scope_principal")
                params["scope_principal"] = actor["principal_id"]
        if search:
            params["search"] = f"%{search.strip()}%"
            clauses.append(
                "(m.employee_id ILIKE :search OR coalesce(profile.full_name, '') ILIKE :search "
                "OR oa.role_id ILIKE :search OR coalesce(l.name, '') ILIKE :search "
                "OR coalesce(s.name, '') ILIKE :search)"
            )
        if role:
            clauses.append("oa.role_id=:role")
            params["role"] = role
        if location_id:
            clauses.append("oa.location_id=:location")
            params["location"] = location_id
        if section_id:
            clauses.append("oa.section_id=:section")
            params["section"] = section_id
        if status:
            clauses.append("oa.status=:status")
            params["status"] = status
        rows = db.execute(text(f"""
            SELECT oa.assignment_id, oa.principal_id, m.employee_id, oa.role_id,
                   oa.location_id, l.name AS location_name,
                   oa.section_id, s.name AS section_name,
                   oa.reports_to_assignment_id,
                   parent_member.employee_id AS reports_to_employee_id,
                   parent.role_id AS reports_to_role_id,
                   oa.status,
                   profile.full_name,
                   profile.email_verified_at IS NOT NULL AS email_verified,
                   profile.phone_verified_at IS NOT NULL AS phone_verified,
                   (profile.id_proof_number IS NOT NULL AND profile.id_proof_number <> '') AS id_proof_supplied,
                   (
                       CASE WHEN profile.full_name IS NOT NULL AND profile.full_name <> '' THEN 1 ELSE 0 END
                       + CASE WHEN profile.email IS NOT NULL AND profile.email <> '' THEN 1 ELSE 0 END
                       + CASE WHEN profile.phone_e164 IS NOT NULL AND profile.phone_e164 <> '' THEN 1 ELSE 0 END
                       + CASE
                           WHEN coalesce(profile.address_line1, '') <> ''
                            AND coalesce(profile.state, '') <> ''
                            AND coalesce(profile.postal_code, '') <> ''
                            AND coalesce(profile.country, '') <> ''
                           THEN 1 ELSE 0 END
                       + CASE
                           WHEN coalesce(profile.id_proof_type, '') <> ''
                            AND coalesce(profile.id_proof_number, '') <> ''
                           THEN 1 ELSE 0 END
                   ) * 20 AS profile_completeness_percent
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            LEFT JOIN organization_member_profiles profile
              ON profile.organization_id=m.organization_id AND profile.principal_id=m.principal_id
            LEFT JOIN locations l
              ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
            LEFT JOIN sections s
              ON s.organization_id=oa.organization_id AND s.section_id=oa.section_id
            LEFT JOIN organizational_assignments parent
              ON parent.assignment_id=oa.reports_to_assignment_id
            LEFT JOIN organization_members parent_member
              ON parent_member.organization_id=parent.organization_id
             AND parent_member.principal_id=parent.principal_id
            WHERE {' AND '.join(clauses)}
            ORDER BY coalesce(lower(profile.full_name), lower(m.employee_id)), oa.assignment_id
        """), params).mappings().all()
        return [dict(row) for row in rows]


def list_assignments(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_read(db, actor)
        scope = _read_scope(db, actor)
        scope_clause = "oa.organization_id=:org"
        params: dict[str, Any] = {"org": actor["organization_id"]}
        if not scope["organization_wide"]:
            if scope["role_id"] == "team_lead":
                scope_clause += """
                  AND EXISTS (
                    SELECT 1
                    FROM organizational_assignments scope_oa
                    WHERE scope_oa.organization_id=oa.organization_id
                      AND scope_oa.principal_id=:scope_principal
                      AND scope_oa.status='active'
                      AND scope_oa.role_id='team_lead'
                      AND scope_oa.location_id=oa.location_id
                      AND scope_oa.section_id=oa.section_id
                  )
                """
                params["scope_principal"] = actor["principal_id"]
            elif scope["role_id"] in {"branch_head", "manager"}:
                scope_clause += """
                  AND EXISTS (
                    SELECT 1
                    FROM organizational_assignments scope_oa
                    WHERE scope_oa.organization_id=oa.organization_id
                      AND scope_oa.principal_id=:scope_principal
                      AND scope_oa.status='active'
                      AND scope_oa.role_id=:scope_role
                      AND scope_oa.location_id=oa.location_id
                  )
                """
                params["scope_principal"] = actor["principal_id"]
                params["scope_role"] = scope["role_id"]
            else:
                scope_clause += " AND oa.principal_id=:scope_principal"
                params["scope_principal"] = actor["principal_id"]
        rows = db.execute(text(f"""
            SELECT oa.assignment_id, oa.organization_id, oa.principal_id, m.employee_id,
                   oa.location_id, l.name AS location_name, oa.role_id,
                   oa.section_id, s.name AS section_name,
                   oa.reports_to_assignment_id, oa.status,
                   parent.principal_id AS reports_to_principal_id,
                   parent_member.employee_id AS reports_to_employee_id,
                   parent.role_id AS reports_to_role_id,
                   profile.full_name,
                   profile.email_verified_at IS NOT NULL AS email_verified,
                   profile.phone_verified_at IS NOT NULL AS phone_verified,
                   (profile.id_proof_number IS NOT NULL AND profile.id_proof_number <> '') AS id_proof_supplied,
                   (
                       CASE WHEN profile.full_name IS NOT NULL AND profile.full_name <> '' THEN 1 ELSE 0 END
                       + CASE WHEN profile.email IS NOT NULL AND profile.email <> '' THEN 1 ELSE 0 END
                       + CASE WHEN profile.phone_e164 IS NOT NULL AND profile.phone_e164 <> '' THEN 1 ELSE 0 END
                       + CASE
                           WHEN coalesce(profile.address_line1, '') <> ''
                            AND coalesce(profile.state, '') <> ''
                            AND coalesce(profile.postal_code, '') <> ''
                            AND coalesce(profile.country, '') <> ''
                           THEN 1 ELSE 0 END
                       + CASE
                           WHEN coalesce(profile.id_proof_type, '') <> ''
                            AND coalesce(profile.id_proof_number, '') <> ''
                           THEN 1 ELSE 0 END
                   ) * 20 AS profile_completeness_percent
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            LEFT JOIN organization_member_profiles profile
              ON profile.organization_id=m.organization_id AND profile.principal_id=m.principal_id
            LEFT JOIN locations l
              ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
            LEFT JOIN sections s
              ON s.organization_id=oa.organization_id AND s.section_id=oa.section_id
            LEFT JOIN organizational_assignments parent
              ON parent.assignment_id=oa.reports_to_assignment_id
            LEFT JOIN organization_members parent_member
              ON parent_member.organization_id=parent.organization_id
             AND parent_member.principal_id=parent.principal_id
            WHERE {scope_clause}
            ORDER BY oa.location_id, oa.section_id, oa.role_id, coalesce(lower(profile.full_name), lower(m.employee_id))
        """), params).mappings().all()
        return [dict(row) for row in rows]


def get_assignment_profile(
    claims: dict[str, Any], workspace_id: str, assignment_id: str
) -> dict[str, Any]:
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        _require_sensitive_profile_read(db, actor)
        scope = _management_scope(db, actor)
        target = _assignment(db, actor["organization_id"], assignment_id)
        if scope["organization_wide"]:
            return _profile_detail(db, actor["organization_id"], assignment_id)
        if scope["role_id"] in {"branch_head", "manager"}:
            if str(target["location_id"]) not in {str(v) for v in scope.get("location_ids", [])}:
                raise AuthzError("Assignment is outside your management scope.")
            return _profile_detail(db, actor["organization_id"], assignment_id)
        if target["principal_id"] != actor["principal_id"]:
            raise AuthzError("Assignment is outside your management scope.")
        return _profile_detail(db, actor["organization_id"], assignment_id)


def _ensure_assignment_role(db, organization_id: str, principal_id: str, role_id: str) -> None:
    exists = db.execute(text("SELECT 1 FROM roles WHERE role_id=:role"), {"role": role_id}).scalar_one_or_none()
    if not exists:
        raise AuthzError("Role is not part of the organization RBAC model.")
    db.execute(text("""
        INSERT INTO member_roles(organization_id, principal_id, role_id)
        VALUES (:org, :principal, :role)
        ON CONFLICT DO NOTHING
    """), {"org": organization_id, "principal": principal_id, "role": role_id})


def assign_manager(claims: dict[str, Any], workspace_id: str,
                   location_id: str, principal_id: str) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        org = actor["organization_id"]
        _require_location_manage(db, actor, location_id)
        location = _location(db, org, location_id)
        if location["status"] != "active":
            raise AuthzError("Cannot assign a manager to an inactive location.")
        candidate = _member_principal(db, org, principal_id)
        existing = db.execute(text("""
            SELECT oa.assignment_id, oa.principal_id, m.employee_id
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            WHERE oa.organization_id=:org AND oa.location_id=:location
              AND oa.role_id='manager' AND oa.status='active'
            LIMIT 1
            FOR UPDATE
        """), {"org": org, "location": location_id}).mappings().first()
        if existing:
            if existing["principal_id"] == candidate["principal_id"]:
                return _assignment(db, org, existing["assignment_id"])
            raise ManagementConflict(
                "This location already has an active manager. Use the manager replacement operation."
            )
        assignment_id = _id("asg")
        _ensure_assignment_role(db, org, candidate["principal_id"], "manager")
        db.execute(text("""
            INSERT INTO organizational_assignments
              (assignment_id, organization_id, principal_id, location_id, role_id, status)
            VALUES (:assignment, :org, :principal, :location, 'manager', 'active')
        """), {"assignment": assignment_id, "org": org, "principal": candidate["principal_id"], "location": location_id})
        _audit(db, org, actor["principal_id"], "management.manager.assigned", "succeeded", {
            "assignment_id": assignment_id, "principal_id": candidate["principal_id"],
            "employee_id": candidate["employee_id"], "location_id": location_id,
        })
        return _assignment(db, org, assignment_id)


def replace_manager(claims: dict[str, Any], workspace_id: str,
                    location_id: str, principal_id: str) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        org = actor["organization_id"]
        _require_location_manage(db, actor, location_id)
        location = _location(db, org, location_id)
        if location["status"] != "active":
            raise AuthzError("Cannot change the manager of an inactive location.")
        candidate = _member_principal(db, org, principal_id)
        current = db.execute(text("""
            SELECT oa.assignment_id, oa.principal_id, m.employee_id
            FROM organizational_assignments oa
            JOIN organization_members m
              ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
            WHERE oa.organization_id=:org AND oa.location_id=:location
              AND oa.role_id='manager' AND oa.status='active'
            LIMIT 1
            FOR UPDATE
        """), {"org": org, "location": location_id}).mappings().first()
        if not current:
            raise ManagementConflict("This location does not currently have an active manager.")
        if current["principal_id"] == candidate["principal_id"]:
            return _assignment(db, org, current["assignment_id"])
        _ensure_assignment_role(db, org, candidate["principal_id"], "manager")
        db.execute(text("""
            UPDATE organizational_assignments
            SET status='inactive', updated_at=now()
            WHERE assignment_id=:assignment
        """), {"assignment": current["assignment_id"]})
        assignment_id = _id("asg")
        db.execute(text("""
            INSERT INTO organizational_assignments
              (assignment_id, organization_id, principal_id, location_id, role_id, status)
            VALUES (:assignment, :org, :principal, :location, 'manager', 'active')
        """), {"assignment": assignment_id, "org": org, "principal": candidate["principal_id"], "location": location_id})
        _audit(db, org, actor["principal_id"], "management.manager.changed", "succeeded", {
            "location_id": location_id,
            "previous_assignment_id": current["assignment_id"],
            "previous_principal_id": current["principal_id"],
            "new_assignment_id": assignment_id,
            "new_principal_id": candidate["principal_id"],
        })
        return _assignment(db, org, assignment_id)


def request_team_lead_assignment(claims: dict[str, Any], workspace_id: str, location_id: str, section_id: str, principal_id: str, reports_to_assignment_id: str | None = None) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        if _management_scope(db, actor)["role_id"] != "manager":
            raise AuthzError("Only a Manager can request a Team Lead assignment.")
        _require_location_manage(db, actor, location_id)
        section = _section(db, actor["organization_id"], section_id)
        if section["location_id"] != location_id or section["status"] != "active":
            raise AuthzError("Section does not belong to the requested active branch.")
        candidate = _member_principal(db, actor["organization_id"], principal_id)
        rid = _id("mreq")
        db.execute(text("""INSERT INTO management_assignment_requests
          (request_id,organization_id,workspace_id,requester_principal_id,location_id,section_id,target_principal_id,reports_to_assignment_id)
          SELECT :id,:org,:workspace,:requester,:location,:section,:target,:reports_to
          WHERE NOT EXISTS (SELECT 1 FROM management_assignment_requests WHERE organization_id=:org AND requester_principal_id=:requester AND target_principal_id=:target AND location_id=:location AND section_id=:section AND status='pending')"""), {
          "id":rid,"org":actor["organization_id"],"workspace":workspace_id,"requester":actor["principal_id"],"location":location_id,"section":section_id,"target":candidate["principal_id"],"reports_to":reports_to_assignment_id})
        existing=db.execute(text("""SELECT request_id FROM management_assignment_requests WHERE organization_id=:org AND requester_principal_id=:requester AND target_principal_id=:target AND location_id=:location AND section_id=:section AND status='pending'"""), {"org":actor["organization_id"],"requester":actor["principal_id"],"target":candidate["principal_id"],"location":location_id,"section":section_id}).scalar_one_or_none()
        return {"request_id": existing or rid, "status":"pending"}


def list_team_lead_requests(claims: dict[str, Any], workspace_id: str) -> list[dict[str, Any]]:
    with SessionLocal() as db:
        actor=_actor(db,claims,workspace_id); scope=_management_scope(db,actor)
        if scope["role_id"] not in {"branch_head","manager"}: raise AuthzError("Team Lead authorization requests are not available to this role.")
        params={"org":actor["organization_id"],"principal":actor["principal_id"]}
        if scope["role_id"]=="branch_head":
            params["locations"]=list(db.execute(text("SELECT location_id FROM organizational_assignments WHERE organization_id=:org AND principal_id=:principal AND role_id='branch_head' AND status='active' AND location_id IS NOT NULL"),params).scalars().all())
            clause="AND r.location_id = ANY(:locations)"
        else: clause="AND r.requester_principal_id=:principal"
        rows=db.execute(text(f"""SELECT r.request_id,r.status,r.location_id,l.name AS location_name,r.section_id,s.name AS section_name,
            requester.employee_id AS requester_employee_id,requester_profile.full_name AS requester_name,
            target.employee_id AS target_employee_id,target_profile.full_name AS target_name,r.created_at,r.reviewed_at
          FROM management_assignment_requests r JOIN locations l ON l.location_id=r.location_id AND l.organization_id=r.organization_id
          JOIN sections s ON s.section_id=r.section_id AND s.organization_id=r.organization_id
          JOIN organization_members requester ON requester.principal_id=r.requester_principal_id AND requester.organization_id=r.organization_id
          LEFT JOIN organization_member_profiles requester_profile ON requester_profile.principal_id=r.requester_principal_id AND requester_profile.organization_id=r.organization_id
          JOIN organization_members target ON target.principal_id=r.target_principal_id AND target.organization_id=r.organization_id
          LEFT JOIN organization_member_profiles target_profile ON target_profile.principal_id=r.target_principal_id AND target_profile.organization_id=r.organization_id
          WHERE r.organization_id=:org {clause} ORDER BY r.created_at DESC"""),params).mappings().all()
        return [dict(x) for x in rows]


def decide_team_lead_request(claims: dict[str, Any], workspace_id: str, request_id: str, approve: bool) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor=_actor(db,claims,workspace_id)
        if _management_scope(db,actor)["role_id"]!="branch_head": raise AuthzError("Only the Branch Head can approve Team Lead assignments.")
        req=db.execute(text("SELECT * FROM management_assignment_requests WHERE organization_id=:org AND request_id=:request AND status='pending' FOR UPDATE"),{"org":actor["organization_id"],"request":request_id}).mappings().first()
        if not req: raise AuthzError("Pending Team Lead authorization request not found.")
        _require_location_manage(db,actor,req["location_id"])
        status="approved" if approve else "rejected"
        if not approve:
            db.execute(text("UPDATE management_assignment_requests SET status='rejected',reviewed_by_principal_id=:reviewer,reviewed_at=now(),updated_at=now() WHERE request_id=:request"),{"reviewer":actor["principal_id"],"request":request_id})
            return {"request_id":request_id,"status":"rejected"}
        parent_id=req["reports_to_assignment_id"]
        if parent_id:
            parent=_assignment(db,actor["organization_id"],parent_id)
            if parent["role_id"]!="manager" or parent["location_id"]!=req["location_id"] or parent["status"]!="active": raise AuthzError("Team Lead must report to an active Manager in the same branch.")
        candidate=_member_principal(db,actor["organization_id"],req["target_principal_id"]); _ensure_assignment_role(db,actor["organization_id"],candidate["principal_id"],"team_lead")
        assignment_id=_id("asg")
        db.execute(text("""INSERT INTO organizational_assignments (assignment_id,organization_id,principal_id,location_id,role_id,section_id,reports_to_assignment_id,status) VALUES (:id,:org,:principal,:location,'team_lead',:section,:parent,'active')"""),{"id":assignment_id,"org":actor["organization_id"],"principal":candidate["principal_id"],"location":req["location_id"],"section":req["section_id"],"parent":parent_id})
        db.execute(text("UPDATE management_assignment_requests SET status='approved',reviewed_by_principal_id=:reviewer,reviewed_at=now(),updated_at=now() WHERE request_id=:request"),{"reviewer":actor["principal_id"],"request":request_id})
        return {"request_id":request_id,"status":status,"assignment_id":assignment_id}


def assign_team_lead(claims: dict[str, Any], workspace_id: str, location_id: str,
                     section_id: str, principal_id: str,
                     reports_to_assignment_id: str | None = None) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        org = actor["organization_id"]
        if _management_scope(db, actor)["role_id"] == "manager":
            raise AuthzError("Managers must request Branch Head approval before assigning a Team Lead.")
        _require_location_manage(db, actor, location_id)
        location = _location(db, org, location_id)
        section = _section(db, org, section_id)
        if location["status"] != "active" or section["status"] != "active":
            raise AuthzError("Location and section must be active.")
        if section["location_id"] != location_id:
            raise AuthzError("Section does not belong to the requested location.")
        candidate = _member_principal(db, org, principal_id)
        parent = None
        if reports_to_assignment_id:
            parent = _assignment(db, org, reports_to_assignment_id)
            if parent["status"] != "active":
                raise AuthzError("Reporting target must be active.")
            if parent["location_id"] != location_id:
                raise AuthzError("Reporting target must belong to the same location.")
            if parent["role_id"] != "manager":
                raise AuthzError("A Team Lead must report to a Manager.")
        duplicate = db.execute(text("""
            SELECT assignment_id FROM organizational_assignments
            WHERE organization_id=:org AND principal_id=:principal
              AND location_id=:location AND section_id=:section
              AND role_id='team_lead' AND status='active'
        """), {"org": org, "principal": candidate["principal_id"], "location": location_id, "section": section_id}).scalar_one_or_none()
        if duplicate:
            return _assignment(db, org, duplicate)
        assignment_id = _id("asg")
        _ensure_assignment_role(db, org, candidate["principal_id"], "team_lead")
        db.execute(text("""
            INSERT INTO organizational_assignments
              (assignment_id, organization_id, principal_id, location_id, role_id,
               section_id, reports_to_assignment_id, status)
            VALUES (:assignment, :org, :principal, :location, 'team_lead',
                    :section, :reports_to, 'active')
        """), {"assignment": assignment_id, "org": org, "principal": candidate["principal_id"],
              "location": location_id, "section": section_id,
              "reports_to": parent["assignment_id"] if parent else None})
        _audit(db, org, actor["principal_id"], "management.team_lead.assigned", "succeeded", {
            "assignment_id": assignment_id, "principal_id": candidate["principal_id"],
            "location_id": location_id, "section_id": section_id,
            "reports_to_assignment_id": parent["assignment_id"] if parent else None,
        })
        return _assignment(db, org, assignment_id)


def set_reporting_relationship(claims: dict[str, Any], workspace_id: str,
                               assignment_id: str,
                               reports_to_assignment_id: str | None) -> dict[str, Any]:
    with SessionLocal.begin() as db:
        actor = _actor(db, claims, workspace_id)
        org = actor["organization_id"]
        target = _assignment(db, org, assignment_id)
        if target["location_id"]:
            _require_location_manage(db, actor, target["location_id"])
        elif "organization.manage" not in _permissions(db, org, actor["principal_id"]):
            raise AuthzError("You don't have permission to manage this assignment.")
        if target["status"] != "active":
            raise AuthzError("Only an active assignment can change reporting.")
        parent = None
        if reports_to_assignment_id:
            if reports_to_assignment_id == assignment_id:
                raise AuthzError("An assignment cannot report to itself.")
            parent = _assignment(db, org, reports_to_assignment_id)
            if parent["status"] != "active":
                raise AuthzError("Reporting target must be active.")
            if target["location_id"] != parent["location_id"]:
                raise AuthzError("Reporting relationships must stay within the same location.")
            child_level = ROLE_LEVELS.get(target["role_id"], 0)
            parent_level = ROLE_LEVELS.get(parent["role_id"], 0)
            if parent_level <= child_level:
                raise AuthzError("Reporting target must have a higher organizational role level.")
        db.execute(text("""
            UPDATE organizational_assignments
            SET reports_to_assignment_id=:parent, updated_at=now()
            WHERE organization_id=:org AND assignment_id=:assignment
        """), {"parent": parent["assignment_id"] if parent else None, "assignment": assignment_id})
        _audit(db, org, actor["principal_id"], "management.assignment.changed", "succeeded", {
            "assignment_id": assignment_id,
            "reports_to_assignment_id": parent["assignment_id"] if parent else None,
        })
        return _assignment(db, org, assignment_id)


def list_audit_events(claims: dict[str, Any], workspace_id: str,
                      limit: int = 100) -> list[dict[str, Any]]:
    limit = max(1, min(int(limit), 200))
    with SessionLocal() as db:
        actor = _actor(db, claims, workspace_id)
        if "audit.view" not in _permissions(db, actor["organization_id"], actor["principal_id"]):
            raise AuthzError("Workspace authorization denied.")
        scope = _management_scope(db, actor)
        if scope["organization_wide"]:
            scope_clause = "organization_id=:org"
            params = {"org": actor["organization_id"], "limit": limit}
        elif scope["role_id"] == "branch_head":
            scope_clause = """organization_id=:org AND EXISTS (
                SELECT 1 FROM organizational_assignments oa
                WHERE oa.organization_id=audit_events.organization_id
                  AND oa.principal_id=:principal AND oa.role_id='branch_head'
                  AND oa.location_id = (audit_events.metadata->>'location_id')
                  AND oa.status='active'
            )"""
            params = {"org": actor["organization_id"], "principal": actor["principal_id"], "limit": limit}
        else:
            scope_clause = "organization_id=:org AND actor_principal_id=:principal"
            params = {"org": actor["organization_id"], "principal": actor["principal_id"], "limit": limit}
        rows = db.execute(text(f"""
            SELECT event_id, actor_principal_id, action, outcome, metadata, created_at
            FROM audit_events
            WHERE {scope_clause}
            ORDER BY created_at DESC
            LIMIT :limit
        """), params).mappings().all()
        return [dict(row) for row in rows]
