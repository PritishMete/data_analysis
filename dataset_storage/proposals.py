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
        "base_version_id": str(row["base_version_id"]),
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


def submit_dataset_proposal(*, workspace_id: str, token: str, dataset_id: str,
                            filename: str, stream: BinaryIO,
                            content_type: str | None) -> dict[str, Any]:
    claims = _claims(token)
    context = _authorization_context(claims, workspace_id)
    roles = set(context.get("role_ids", []))
    if "manager" not in roles or "dataset.propose" not in set(context.get("permissions", [])):
        raise PermissionDenied("Only a Manager with explicit proposal-submit permission may submit changes.")
    scope = authorize_dataset(claims, workspace_id, dataset_id, "dataset.view_original")
    if not scope.get("protected_original") or not scope.get("location_id"):
        raise AuthzError("Only an existing branch-scoped original dataset can receive a proposal.")
    location_id = str(scope["location_id"])
    organization_id = str(context["organization_id"])
    principal_id = str(context["principal_id"])
    workspace_id = str(context["workspace_id"])
    provider, provider_subject = _identity(claims)
    safe_name = _safe_filename(filename)

    repo = DatasetRepository(SessionLocal())
    registration = None
    proposal_id = "dsp_" + uuid.uuid4().hex
    candidate_version_id = "p" + uuid.uuid4().hex
    try:
        dataset = repo.get_by_id(dataset_id)
        if dataset is None or dataset.organization_id != organization_id or dataset.status != "ready" or not dataset.current_version_id:
            raise FileNotFoundError("Published original dataset not found.")
        base_version_id = str(dataset.current_version_id)
        registration = DatasetRegistryService(repo).register_csv_stream(
            file_obj=stream,
            filename=safe_name,
            organization_id=organization_id,
            dataset_name=dataset.dataset_name,
            uploaded_by=principal_id,
            existing_dataset_id=dataset_id,
            content_type=content_type or "text/csv",
            max_bytes=MAX_DATASET_BYTES,
            candidate_version_id=candidate_version_id,
        )
        if registration.registration.was_duplicate:
            raise ValueError("A proposal must contain a distinct candidate file.")
        candidate = registration.version
        with repo.db.begin():
            locked = repo.db.execute(
                select(Dataset).where(Dataset.dataset_id == dataset_id).with_for_update()
            ).scalar_one_or_none()
            if locked is None or locked.organization_id != organization_id:
                raise FileNotFoundError("Published original dataset not found.")
            if locked.status != "ready" or locked.current_version_id != base_version_id:
                raise AuthzError("The official dataset changed while this proposal was being submitted.")
            _revalidate_assignment(
                repo.db, organization_id=organization_id, workspace_id=workspace_id,
                principal_id=principal_id, location_id=location_id, role_id="manager",
                provider=provider, provider_subject=provider_subject,
                require_proposal_permission=True,
            )
            repo.db.execute(text("""
                INSERT INTO dataset_change_proposals
                    (proposal_id, organization_id, workspace_id, dataset_id, location_id,
                     candidate_version_pk, candidate_version_id, submitted_by_principal_id,
                     base_version_id, status, original_filename, file_size, file_hash)
                VALUES (:proposal, :org, :workspace, :dataset, :location,
                        :candidate_pk, :candidate_id, :submitter, :base, 'pending',
                        :filename, :size, :hash)
            """), {
                "proposal": proposal_id, "org": organization_id, "workspace": workspace_id,
                "dataset": dataset_id, "location": location_id,
                "candidate_pk": candidate.version_pk, "candidate_id": candidate.version_id,
                "submitter": principal_id, "base": base_version_id,
                "filename": safe_name, "size": candidate.file_size, "hash": candidate.file_hash,
            })
            _audit(repo.db, organization_id=organization_id, principal_id=principal_id,
                   action="dataset.proposal.submit", outcome="succeeded", proposal_id=proposal_id,
                   metadata={"dataset_id": dataset_id, "location_id": location_id,
                             "base_version_id": base_version_id,
                             "candidate_version_id": candidate.version_id})
        return {"proposal_id": proposal_id, "dataset_id": dataset_id,
                "candidate_version_id": candidate.version_id, "base_version_id": base_version_id,
                "status": "pending", "submitted_at": candidate.created_at.isoformat()}
    except Exception as exc:
        repo.db.rollback()
        if registration is not None and not registration.registration.was_duplicate:
            try:
                from .service import _discard_sql_registration
                _discard_sql_registration(repo, dataset_id, candidate_version_id, False)
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
            _revalidate_assignment(
                repo.db, organization_id=organization_id, workspace_id=workspace_id,
                principal_id=principal_id, location_id=str(proposal["location_id"]),
                role_id="branch_head", provider=provider, provider_subject=provider_subject,
            )
            dataset = repo.db.execute(
                select(Dataset).where(Dataset.dataset_id == proposal["dataset_id"]).with_for_update()
            ).scalar_one_or_none()
            if dataset is None or dataset.organization_id != organization_id:
                raise FileNotFoundError("Original dataset not found.")
            if dataset.current_version_id != proposal["base_version_id"]:
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
                DatasetRegistryService(repo).finalize_version(
                    dataset.dataset_id, candidate.version_id,
                    expected_current_version_id=str(proposal["base_version_id"]), commit=False,
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
