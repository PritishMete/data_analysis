from __future__ import annotations

import uuid
from typing import Any, BinaryIO

from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError

from core.db import SessionLocal
from datasets.models import Dataset, DatasetVersion
from datasets.repository import DatasetRepository
from datasets.service import DatasetRegistryService
from firebase_authz.service import AuthzError, PermissionDenied
from firebase_authz.supabase_provider import _identity, authorize_dataset
from .service import MAX_DATASET_BYTES, _claims, _safe_filename, _authorization_context


def _audit(db, *, organization_id: str, principal_id: str, action: str,
           outcome: str, proposal_id: str, metadata: dict[str, Any] | None = None) -> None:
    import json
    payload = {"proposal_id": proposal_id, **(metadata or {})}
    db.execute(text("""
        INSERT INTO audit_events
            (event_id, organization_id, actor_principal_id, action, outcome, metadata)
        VALUES (:event, :org, :principal, :action, :outcome, CAST(:metadata AS jsonb))
    """), {
        "event": "evt_" + uuid.uuid4().hex,
        "org": organization_id,
        "principal": principal_id,
        "action": action,
        "outcome": outcome,
        "metadata": json.dumps(payload),
    })


def _revalidate_assignment(db, *, organization_id: str, workspace_id: str,
                           principal_id: str, location_id: str, role_id: str,
                           provider: str, provider_subject: str,
                           require_proposal_permission: bool = False) -> None:
    permission_join = """
        JOIN role_permissions rp
          ON rp.role_id=oa.role_id AND rp.permission_id='dataset.propose'
    """ if require_proposal_permission else ""
    lock_targets = "oa, l, m, mr, ib, o, w" + (", rp" if require_proposal_permission else "")
    row = db.execute(text(f"""
        SELECT oa.assignment_id
        FROM organizational_assignments oa
        JOIN locations l
          ON l.organization_id=oa.organization_id AND l.location_id=oa.location_id
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
        JOIN member_roles mr
          ON mr.organization_id=oa.organization_id
         AND mr.principal_id=oa.principal_id AND mr.role_id=oa.role_id
        JOIN identity_bindings ib
          ON ib.principal_id=m.principal_id AND ib.status='active'
         AND ib.provider=:provider AND ib.provider_subject=:provider_subject
        JOIN organizations o ON o.organization_id=m.organization_id AND o.status='active'
        JOIN workspaces w ON w.workspace_id=m.workspace_id AND w.status='active'
        {permission_join}
        WHERE oa.organization_id=:org AND m.workspace_id=:workspace
          AND oa.principal_id=:principal AND oa.location_id=:location
          AND oa.role_id=:role AND oa.status='active'
          AND m.status='active' AND l.status='active'
        ORDER BY oa.assignment_id
        LIMIT 1 FOR SHARE OF {lock_targets}
    """), {
        "org": organization_id, "workspace": workspace_id,
        "principal": principal_id, "location": location_id, "role": role_id,
        "provider": provider, "provider_subject": provider_subject,
    }).scalar_one_or_none()
    if row is None:
        raise PermissionDenied("An active membership and assignment to this exact branch are required.")


def _proposal_dict(row) -> dict[str, Any]:
    return {
        "proposal_id": str(row["proposal_id"]),
        "organization_id": str(row["organization_id"]),
        "workspace_id": str(row["workspace_id"]),
        "dataset_id": str(row["dataset_id"]),
        "location_id": str(row["location_id"]),
        "candidate_version_id": str(row["candidate_version_id"]),
        "base_version_id": str(row["base_version_id"]) if row["base_version_id"] is not None else None,
        "dataset_kind": str(row.get("dataset_kind") or "existing"),
        "upload_grant_id": str(row["upload_grant_id"]) if row.get("upload_grant_id") else None,
        "submitted_by_principal_id": str(row["submitted_by_principal_id"]),
        "status": str(row["status"]),
        "original_filename": str(row["original_filename"]),
        "file_size": int(row["file_size"]),
        "file_hash": str(row["file_hash"]),
        "submitted_at": row["submitted_at"].isoformat() if row["submitted_at"] else None,
        "reviewed_by_principal_id": row["reviewed_by_principal_id"],
        "reviewed_at": row["reviewed_at"].isoformat() if row["reviewed_at"] else None,
        "decision_note": row["decision_note"],
    }


def _active_manager_grant(db, *, organization_id: str, workspace_id: str,
                          principal_id: str, location_id: str,
                          provider: str, provider_subject: str,
                          lock: bool = False) -> str:
    lock_clause = " FOR SHARE OF g, oa, m, mr, l" if lock else ""
    grant = db.execute(text(f"""
        SELECT g.grant_id
        FROM manager_dataset_upload_grants g
        JOIN organizational_assignments oa
          ON oa.organization_id=g.organization_id
         AND oa.principal_id=g.manager_principal_id
         AND oa.location_id=g.location_id AND oa.role_id='manager'
         AND oa.status='active'
        JOIN organization_members m
          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
         AND m.workspace_id=g.workspace_id AND m.status='active'
        JOIN member_roles mr
          ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
         AND mr.role_id='manager'
        JOIN identity_bindings ib
          ON ib.principal_id=m.principal_id AND ib.status='active'
         AND ib.provider=:provider AND ib.provider_subject=:subject
        JOIN locations l
          ON l.organization_id=g.organization_id AND l.location_id=g.location_id
         AND l.status='active'
        WHERE g.organization_id=:org AND g.workspace_id=:workspace
          AND g.manager_principal_id=:principal AND g.location_id=:location
          AND g.revoked_at IS NULL
        LIMIT 1{lock_clause}
    """), {"org": organization_id, "workspace": workspace_id,
            "principal": principal_id, "location": location_id,
            "provider": provider, "subject": provider_subject}).scalar_one_or_none()
    if grant is None:
        raise PermissionDenied("An active, branch-specific Manager upload grant is required.")
    return str(grant)


def submit_dataset_proposal(*, workspace_id: str, token: str, dataset_id: str | None,
                            filename: str, stream: BinaryIO,
                            content_type: str | None,
                            location_id: str | None = None) -> dict[str, Any]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if "manager" not in roles:
        raise PermissionDenied("Only a Manager may submit a dataset for Branch Head review.")
    organization_id = str(context["organization_id"])
    principal_id = str(context["principal_id"])
    workspace_id = str(context["workspace_id"])
    provider, provider_subject = _identity(claims)
    safe_name = _safe_filename(filename)

    # Existing originals derive branch scope exclusively from the authoritative
    # dataset ACL. First-publication submissions require an explicit branch ID.
    if dataset_id:
        scope = authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
        if not scope.get("protected_original") or not scope.get("location_id"):
            raise AuthzError("Only a branch-scoped original dataset can receive a proposal.")
        location_id = str(scope["location_id"])
    else:
        location_id = str(location_id or "").strip()
        if not location_id:
            raise ValueError("location_id is required for a new-dataset proposal.")

    repo = DatasetRepository(SessionLocal())
    registration = None
    proposal_id = "dsp_" + uuid.uuid4().hex
    candidate_version_id = "p" + uuid.uuid4().hex
    is_new = dataset_id is None
    base_version_id: str | None = None
    try:
        # Fail before consuming/persisting a candidate unless the exact branch
        # grant and active Manager assignment both exist.
        grant_id = _active_manager_grant(
            repo.db, organization_id=organization_id, workspace_id=workspace_id,
            principal_id=principal_id, location_id=location_id,
            provider=provider, provider_subject=provider_subject,
        )
        if not is_new:
            dataset = repo.get_by_id(str(dataset_id))
            if (dataset is None or dataset.organization_id != organization_id
                    or dataset.status != "ready" or not dataset.current_version_id):
                raise FileNotFoundError("Published original dataset not found.")
            base_version_id = str(dataset.current_version_id)

        registration = DatasetRegistryService(repo).register_csv_stream(
            file_obj=stream, filename=safe_name, organization_id=organization_id,
            dataset_name=safe_name, uploaded_by=principal_id,
            existing_dataset_id=None if is_new else str(dataset_id),
            content_type=content_type or "text/csv", max_bytes=MAX_DATASET_BYTES,
            candidate_version_id=candidate_version_id,
        )
        if registration.registration.was_duplicate:
            raise ValueError("A proposal must contain a distinct candidate file.")

        dataset = registration.registration.dataset
        with repo.db.begin():
            locked = repo.db.execute(
                select(Dataset).where(Dataset.dataset_id == dataset.dataset_id).with_for_update()
            ).scalar_one_or_none()
            if locked is None or locked.organization_id != organization_id:
                raise FileNotFoundError("Candidate dataset not found.")
            if is_new:
                if locked.status != "processing" or locked.current_version_id is not None:
                    raise AuthzError("New dataset candidate is not isolated for first publication.")
                # A staged dataset must have no authorization resource until approved.
                existing_acl = repo.db.execute(text("""
                    SELECT 1 FROM dataset_authorization
                    WHERE organization_id=:org AND dataset_id=:dataset
                    FOR UPDATE
                """), {"org": organization_id, "dataset": locked.dataset_id}).scalar_one_or_none()
                if existing_acl is not None:
                    raise AuthzError("An unpublished candidate cannot already have an authorization record.")
            else:
                if locked.status != "ready" or locked.current_version_id != base_version_id:
                    raise AuthzError("The official dataset changed while this proposal was being submitted.")
                current_scope = repo.db.execute(text("""
                    SELECT location_id, status, protected_original
                    FROM dataset_authorization
                    WHERE organization_id=:org AND dataset_id=:dataset
                    FOR UPDATE
                """), {"org": organization_id, "dataset": locked.dataset_id}).mappings().first()
                if (current_scope is None or current_scope["status"] != "active"
                        or not current_scope["protected_original"]
                        or str(current_scope["location_id"] or "") != location_id):
                    raise AuthzError("The original dataset branch assignment changed during submission.")

            _revalidate_assignment(
                repo.db, organization_id=organization_id, workspace_id=workspace_id,
                principal_id=principal_id, location_id=location_id, role_id="manager",
                provider=provider, provider_subject=provider_subject,
            )
            # Recheck and lock the persistent grant in the same transaction that
            # records the proposal; revocation cannot race through this boundary.
            grant_id = _active_manager_grant(
                repo.db, organization_id=organization_id, workspace_id=workspace_id,
                principal_id=principal_id, location_id=location_id,
                provider=provider, provider_subject=provider_subject, lock=True,
            )
            repo.db.execute(text("""
                INSERT INTO dataset_change_proposals
                    (proposal_id, organization_id, workspace_id, dataset_id, location_id,
                     candidate_version_pk, candidate_version_id, submitted_by_principal_id,
                     base_version_id, dataset_kind, upload_grant_id, status,
                     original_filename, file_size, file_hash)
                VALUES (:proposal, :org, :workspace, :dataset, :location,
                        :candidate_pk, :candidate_id, :submitter, :base, :kind, :grant,
                        'pending', :filename, :size, :hash)
            """), {
                "proposal": proposal_id, "org": organization_id, "workspace": workspace_id,
                "dataset": locked.dataset_id, "location": location_id,
                "candidate_pk": registration.version.version_pk,
                "candidate_id": registration.version.version_id, "submitter": principal_id,
                "base": base_version_id, "kind": "new" if is_new else "existing",
                "grant": grant_id, "filename": safe_name,
                "size": registration.version.file_size, "hash": registration.version.file_hash,
            })
            _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                   action="dataset.proposal.submit", outcome="succeeded", proposal_id=proposal_id,
                   metadata={"dataset_id": locked.dataset_id, "location_id": location_id,
                             "dataset_kind": "new" if is_new else "existing",
                             "base_version_id": base_version_id,
                             "candidate_version_id": registration.version.version_id,
                             "upload_grant_id": grant_id})
        return {"proposal_id": proposal_id, "dataset_id": locked.dataset_id,
                "dataset_kind": "new" if is_new else "existing",
                "candidate_version_id": registration.version.version_id,
                "base_version_id": base_version_id, "status": "pending",
                "submitted_at": registration.version.created_at.isoformat()}
    except Exception as exc:
        repo.db.rollback()
        if registration is not None and not registration.registration.was_duplicate:
            try:
                from .service import _discard_sql_registration
                _discard_sql_registration(
                    repo, registration.registration.dataset.dataset_id,
                    candidate_version_id, is_new,
                )
            except Exception:
                pass
        if isinstance(exc, IntegrityError) and "uq_dataset_change_pending_content" in str(exc.orig):
            raise AuthzError("An identical proposal is already pending for this dataset version.") from exc
        raise
    finally:
        repo.db.close()


def list_dataset_proposals(*, workspace_id: str, token: str) -> list[dict[str, Any]]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if not roles.intersection({"manager", "branch_head"}):
        raise PermissionDenied("Only Managers and Branch Heads may view dataset proposals.")
    with SessionLocal() as db:
        if "branch_head" in roles:
            rows = db.execute(text("""
                SELECT p.* FROM dataset_change_proposals p
                WHERE p.organization_id=:org AND p.workspace_id=:workspace
                  AND EXISTS (
                    SELECT 1 FROM organizational_assignments oa
                    JOIN locations l ON l.organization_id=oa.organization_id
                      AND l.location_id=oa.location_id AND l.status='active'
                    JOIN organization_members m
                      ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                    JOIN member_roles mr
                      ON mr.organization_id=oa.organization_id AND mr.principal_id=oa.principal_id
                     AND mr.role_id='branch_head'
                    WHERE oa.organization_id=p.organization_id
                      AND oa.principal_id=:principal AND oa.location_id=p.location_id
                      AND oa.role_id='branch_head' AND oa.status='active'
                      AND m.workspace_id=p.workspace_id AND m.status='active'
                  )
                ORDER BY p.submitted_at DESC
            """), {"org": context["organization_id"], "workspace": context["workspace_id"],
                    "principal": context["principal_id"]}).mappings().all()
        else:
            rows = db.execute(text("""
                SELECT p.* FROM dataset_change_proposals p
                WHERE p.organization_id=:org AND p.workspace_id=:workspace
                  AND p.submitted_by_principal_id=:principal
                ORDER BY p.submitted_at DESC
            """), {"org": context["organization_id"], "workspace": context["workspace_id"],
                    "principal": context["principal_id"]}).mappings().all()
        return [_proposal_dict(row) for row in rows]


def decide_dataset_proposal(*, workspace_id: str, token: str, proposal_id: str,
                            approve: bool, decision_note: str | None = None) -> dict[str, Any]:
    if decision_note is not None and not isinstance(decision_note, str):
        raise ValueError("Decision note must be text.")
    note = (decision_note or "").strip()
    if len(note) > 1000 or any(ord(c) < 32 and c not in "\t\n\r" for c in note):
        raise ValueError("Decision note must be at most 1000 safe characters.")
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    if "branch_head" not in set(context.get("role_ids", [])):
        raise PermissionDenied("Only a Branch Head may review dataset proposals.")
    organization_id = str(context["organization_id"])
    workspace_id = str(context["workspace_id"])
    principal_id = str(context["principal_id"])
    provider, provider_subject = _identity(claims)
    repo = DatasetRepository(SessionLocal())
    try:
        with repo.db.begin():
            proposal = repo.db.execute(text("""
                SELECT * FROM dataset_change_proposals
                WHERE proposal_id=:proposal AND organization_id=:org AND workspace_id=:workspace
                FOR UPDATE
            """), {"proposal": proposal_id, "org": organization_id, "workspace": workspace_id}).mappings().first()
            if proposal is None:
                raise FileNotFoundError("Dataset proposal not found.")
            if proposal["status"] != "pending":
                raise AuthzError("This proposal has already been decided or is no longer pending.")
            if str(proposal["submitted_by_principal_id"]) == principal_id:
                raise PermissionDenied("A Branch Head cannot review their own proposal.")
            dataset = repo.db.execute(
                select(Dataset).where(Dataset.dataset_id == proposal["dataset_id"]).with_for_update()
            ).scalar_one_or_none()
            if dataset is None or dataset.organization_id != organization_id:
                raise FileNotFoundError("Original dataset not found.")
            current_scope = repo.db.execute(text("""
                SELECT location_id, status, protected_original
                FROM dataset_authorization
                WHERE organization_id=:org AND dataset_id=:dataset
                FOR UPDATE
            """), {"org": organization_id, "dataset": dataset.dataset_id}).mappings().first()
            _revalidate_assignment(
                repo.db, organization_id=organization_id, workspace_id=workspace_id,
                principal_id=principal_id, location_id=str(proposal["location_id"]),
                role_id="branch_head", provider=provider, provider_subject=provider_subject,
            )
            # Serialize review against grant revocation and verify the submitter
            # still has an active Manager assignment to this exact branch.
            active_grant = repo.db.execute(text("""
                SELECT g.grant_id
                FROM manager_dataset_upload_grants g
                JOIN organizational_assignments oa
                  ON oa.organization_id=g.organization_id
                 AND oa.principal_id=g.manager_principal_id
                 AND oa.location_id=g.location_id AND oa.role_id='manager'
                 AND oa.status='active'
                JOIN organization_members m
                  ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                 AND m.workspace_id=g.workspace_id AND m.status='active'
                JOIN member_roles mr
                  ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
                 AND mr.role_id='manager'
                JOIN identity_bindings ib
                  ON ib.principal_id=m.principal_id AND ib.status='active'
                JOIN locations l
                  ON l.organization_id=g.organization_id AND l.location_id=g.location_id
                 AND l.status='active'
                WHERE g.grant_id=:grant AND g.organization_id=:org
                  AND g.workspace_id=:workspace
                  AND g.manager_principal_id=:submitter
                  AND g.location_id=:location AND g.revoked_at IS NULL
                FOR SHARE OF g, oa, m, mr, l
            """), {"grant": proposal["upload_grant_id"], "org": organization_id,
                    "workspace": workspace_id, "submitter": proposal["submitted_by_principal_id"],
                    "location": proposal["location_id"]}).scalar_one_or_none()
            is_new = str(proposal.get("dataset_kind") or "existing") == "new"
            scope_invalid = (
                (is_new and (current_scope is not None or dataset.status != "processing"
                             or dataset.current_version_id is not None))
                or (not is_new and (
                    current_scope is None or current_scope["status"] != "active"
                    or not current_scope["protected_original"]
                    or str(current_scope["location_id"] or "") != str(proposal["location_id"])
                ))
            )
            if active_grant is None or scope_invalid:
                reason = ("Manager upload grant was revoked or assignment changed after submission."
                          if active_grant is None else
                          "Original dataset branch assignment changed after submission.")
                repo.db.execute(text("""
                    UPDATE dataset_change_proposals
                    SET status='stale', reviewed_by_principal_id=:reviewer,
                        reviewed_at=now(), decision_note=:reason
                    WHERE proposal_id=:proposal AND status='pending'
                """), {"reviewer": principal_id, "proposal": proposal_id, "reason": reason})
                _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                       action="dataset.proposal.stale", outcome="stale", proposal_id=proposal_id,
                       metadata={"dataset_id": dataset.dataset_id, "reason": reason})
                result = {"proposal_id": proposal_id, "status": "stale"}
            elif not is_new and dataset.current_version_id != proposal["base_version_id"]:
                repo.db.execute(text("""
                    UPDATE dataset_change_proposals
                    SET status='stale', reviewed_by_principal_id=:reviewer,
                        reviewed_at=now(), decision_note=:note
                    WHERE proposal_id=:proposal AND status='pending'
                """), {"reviewer": principal_id, "note": note or "Official dataset changed after submission.",
                        "proposal": proposal_id})
                _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                       action="dataset.proposal.stale", outcome="stale", proposal_id=proposal_id,
                       metadata={"dataset_id": proposal["dataset_id"],
                                 "base_version_id": proposal["base_version_id"],
                                 "current_version_id": dataset.current_version_id})
                result = {"proposal_id": proposal_id, "status": "stale"}
            elif not approve:
                repo.db.execute(text("""
                    UPDATE dataset_change_proposals
                    SET status='rejected', reviewed_by_principal_id=:reviewer,
                        reviewed_at=now(), decision_note=:note
                    WHERE proposal_id=:proposal AND status='pending'
                """), {"reviewer": principal_id, "note": note or None, "proposal": proposal_id})
                _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                       action="dataset.proposal.reject", outcome="succeeded", proposal_id=proposal_id,
                       metadata={"dataset_id": proposal["dataset_id"], "decision_note": note or None})
                result = {"proposal_id": proposal_id, "status": "rejected"}
            else:
                candidate = repo.db.get(DatasetVersion, str(proposal["candidate_version_pk"]))
                if candidate is None or candidate.dataset_id != dataset.dataset_id or candidate.status != "processing":
                    raise AuthzError("The private candidate version is not available for publication.")
                if is_new:
                    # Publish ACL/resource records in the same transaction as the
                    # READY transition and proposal decision. No client can observe
                    # a READY dataset without its branch authorization.
                    repo.db.execute(text("""
                        INSERT INTO authorization_resources
                          (organization_id, resource_id, resource_type, owner_principal_id)
                        VALUES (:org, :dataset, 'dataset', :owner)
                    """), {"org": organization_id, "dataset": dataset.dataset_id,
                            "owner": principal_id})
                    repo.db.execute(text("""
                        INSERT INTO dataset_authorization
                          (organization_id, dataset_id, owner_principal_id,
                           protected_original, location_id, status)
                        VALUES (:org, :dataset, :owner, TRUE, :location, 'active')
                    """), {"org": organization_id, "dataset": dataset.dataset_id,
                            "owner": principal_id, "location": proposal["location_id"]})
                    # Branch Heads assigned to this branch can review and manage
                    # the authoritative original; the submitting Manager receives
                    # view-only access after approval.
                    repo.db.execute(text("""
                        INSERT INTO resource_grants
                          (organization_id, resource_id, principal_id, permissions)
                        SELECT :org, :dataset, oa.principal_id,
                               CAST(:head_permissions AS jsonb)
                        FROM organizational_assignments oa
                        JOIN organization_members m
                          ON m.organization_id=oa.organization_id AND m.principal_id=oa.principal_id
                         AND m.workspace_id=:workspace AND m.status='active'
                        JOIN member_roles mr
                          ON mr.organization_id=m.organization_id AND mr.principal_id=m.principal_id
                         AND mr.role_id='branch_head'
                        WHERE oa.organization_id=:org AND oa.location_id=:location
                          AND oa.role_id='branch_head' AND oa.status='active'
                        ON CONFLICT (organization_id, resource_id, principal_id)
                        DO UPDATE SET permissions=EXCLUDED.permissions
                    """), {"org": organization_id, "dataset": dataset.dataset_id,
                            "workspace": workspace_id, "location": proposal["location_id"],
                            "head_permissions": '["dataset.view_original","dataset.create_working_copy","dataset.manage_acl"]'})
                    repo.db.execute(text("""
                        INSERT INTO resource_grants
                          (organization_id, resource_id, principal_id, permissions)
                        VALUES (:org, :dataset, :manager, CAST(:permissions AS jsonb))
                        ON CONFLICT (organization_id, resource_id, principal_id)
                        DO UPDATE SET permissions=EXCLUDED.permissions
                    """), {"org": organization_id, "dataset": dataset.dataset_id,
                            "manager": proposal["submitted_by_principal_id"],
                            "permissions": '["dataset.view_original"]'})
                DatasetRegistryService(repo).finalize_version(
                    dataset.dataset_id, candidate.version_id,
                    expected_current_version_id=(None if is_new else str(proposal["base_version_id"])),
                    commit=False,
                )
                repo.db.execute(text("""
                    UPDATE dataset_change_proposals
                    SET status='approved', reviewed_by_principal_id=:reviewer,
                        reviewed_at=now(), decision_note=:note
                    WHERE proposal_id=:proposal AND status='pending'
                """), {"reviewer": principal_id, "note": note or None, "proposal": proposal_id})
                _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                       action="dataset.proposal.approve", outcome="succeeded", proposal_id=proposal_id,
                       metadata={"dataset_id": dataset.dataset_id,
                                 "published_version_id": candidate.version_id,
                                 "base_version_id": proposal["base_version_id"]})
                result = {"proposal_id": proposal_id, "status": "approved",
                          "dataset_id": dataset.dataset_id, "published_version_id": candidate.version_id}
        return result
    finally:
        repo.db.close()
