"""Fail-closed configuration checks for the isolated QA deployment."""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import urlparse


QA_PROJECT_REF = "xcnjauxmofqkwnpdazpj"
PRODUCTION_PROJECT_REF = "zfdgwnipdyrpbardqoql"
QA_SUPABASE_HOST = f"{QA_PROJECT_REF}.supabase.co"
QA_DATABASE_HOST = f"db.{QA_PROJECT_REF}.supabase.co"
PRODUCTION_DATABASE_HOST = f"db.{PRODUCTION_PROJECT_REF}.supabase.co"


class QAEnvironmentError(RuntimeError):
    """Raised when the QA process cannot prove it is isolated."""


@dataclass(frozen=True)
class QAEnvironment:
    supabase_url: str
    project_ref: str
    database_host: str


def validate_qa_environment(environ: dict[str, str] | None = None) -> QAEnvironment | None:
    """Validate QA-only identity before any startup DDL can run.

    Production startup is intentionally unaffected: this function is a no-op
    unless ``INSIGHTFLOW_ENV=qa``. The project and database hosts are pinned
    independently to Supabase control-plane metadata, not trusted from a
    self-declared environment allowlist.
    """
    env = os.environ if environ is None else environ
    if env.get("INSIGHTFLOW_ENV", "").strip().lower() != "qa":
        return None

    project_ref = env.get("SUPABASE_PROJECT_REF", "").strip()
    supabase_url = env.get("SUPABASE_URL", "").strip().rstrip("/")
    database_url = env.get("DATABASE_URL", "").strip()
    allowed_db_host = env.get("INSIGHTFLOW_QA_DATABASE_HOST", "").strip().lower()
    authn_mode = env.get("AUTHN_PROVIDER_MODE", "").strip().lower()
    persistence_mode = env.get("AUTHZ_PERSISTENCE_PROVIDER", "").strip().lower()

    if not project_ref or project_ref == PRODUCTION_PROJECT_REF:
        raise QAEnvironmentError("QA Supabase project identity is missing or production.")
    if project_ref != QA_PROJECT_REF:
        raise QAEnvironmentError("QA Supabase project identity is not allowlisted.")
    parsed_supabase = urlparse(supabase_url)
    if (
        parsed_supabase.scheme != "https"
        or parsed_supabase.hostname != QA_SUPABASE_HOST
        or parsed_supabase.path not in ("", "/")
        or parsed_supabase.query
        or parsed_supabase.fragment
    ):
        raise QAEnvironmentError("QA Supabase URL is not the allowlisted project URL.")
    if not database_url or database_url.startswith(("sqlite:", "sqlite+")):
        raise QAEnvironmentError("QA requires an explicit PostgreSQL DATABASE_URL.")
    parsed_db = urlparse(database_url)
    db_host = (parsed_db.hostname or "").lower()
    if parsed_db.scheme not in {"postgresql", "postgresql+psycopg", "postgresql+psycopg2"}:
        raise QAEnvironmentError("QA DATABASE_URL must use PostgreSQL.")
    if db_host == PRODUCTION_DATABASE_HOST:
        raise QAEnvironmentError("QA database target is the production database.")
    if (
        db_host != QA_DATABASE_HOST
        or allowed_db_host != QA_DATABASE_HOST
        or not parsed_db.username
        or not parsed_db.password
        or not parsed_db.path.strip("/")
    ):
        raise QAEnvironmentError("QA database host is missing or not the independently pinned QA database.")
    if PRODUCTION_PROJECT_REF in database_url.lower():
        raise QAEnvironmentError("QA database target matches the production project.")
    if authn_mode != "supabase" or persistence_mode != "supabase":
        raise QAEnvironmentError("QA authentication and persistence providers must be Supabase.")
    return QAEnvironment(supabase_url, project_ref, db_host)
