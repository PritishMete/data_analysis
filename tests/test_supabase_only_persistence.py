from __future__ import annotations

from pathlib import Path

import pytest

from firebase_authz import management_domain, middleware, routes, supabase_provider


ROOT = Path(__file__).resolve().parents[1]


def test_postgres_provider_identity_ignores_firebase_jwt_metadata():
    claims = {
        "uid": "supabase-user-uuid",
        "sub": "supabase-user-uuid",
        "provider": "supabase",
        "firebase": {
            "sign_in_provider": "google.com",
            "identities": {"google.com": ["attacker-controlled-provider-subject"]},
        },
    }

    assert supabase_provider._identity(claims) == ("supabase", "supabase-user-uuid")
    assert management_domain._identity(claims) == ("supabase", "supabase-user-uuid")


def test_postgres_provider_rejects_missing_stable_subject():
    with pytest.raises(Exception, match="Authenticated Supabase identity is required"):
        supabase_provider._identity({"uid": "not-a-verified-subject", "email": "employee@example.com"})
    with pytest.raises(Exception, match="Authenticated Supabase identity is required"):
        management_domain._identity({"uid": "not-a-verified-subject", "email": "employee@example.com"})


def test_supabase_provider_does_not_query_or_write_legacy_firebase_identity_columns():
    source = (ROOT / "firebase_authz" / "supabase_provider.py").read_text(encoding="utf-8")
    assert 'claims.get("firebase")' not in source
    assert "provider='firebase'" not in source
    assert "firebase_uid" not in source


def test_management_domain_does_not_derive_identity_from_firebase_claims():
    source = (ROOT / "firebase_authz" / "management_domain.py").read_text(encoding="utf-8")
    assert 'claims.get("firebase")' not in source
    assert 'sign_in_provider' not in source


def test_middleware_has_no_legacy_rtdb_authorization_fallback():
    source = (ROOT / "firebase_authz" / "middleware.py").read_text(encoding="utf-8")
    assert "authorization(uid, workspace_id" not in source
    assert "Supabase/PostgreSQL is the only supported provider." in source
    assert 'os.getenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")' in source


def test_authz_routes_default_to_postgres_and_reject_legacy_provider_configuration():
    source = (ROOT / "firebase_authz" / "routes.py").read_text(encoding="utf-8")
    assert 'os.environ.get("AUTHZ_PERSISTENCE_PROVIDER", "firebase")' not in source
    assert "Unsupported AUTHZ_PERSISTENCE_PROVIDER." in source
    assert '_supabase_persistence_enabled()' in source


@pytest.mark.parametrize("legacy_provider", ["firebase", "dual", ""])
def test_routes_and_middleware_fail_closed_for_legacy_persistence(monkeypatch, legacy_provider):
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", legacy_provider)
    with pytest.raises(RuntimeError, match="only supported provider"):
        routes._supabase_persistence_enabled()
    with pytest.raises(RuntimeError, match="only supported provider"):
        middleware._require_postgres_persistence()


def test_application_authorization_code_has_no_active_rtdb_or_firebase_admin_path():
    production_paths = [
        path
        for path in ROOT.rglob("*.py")
        if "tests" not in path.relative_to(ROOT).parts
        and not path.name.startswith(("test", "tempCodeRunner"))
        and not any(part in {".git", ".venv", "frontend", "flutter_detail_source"} for part in path.relative_to(ROOT).parts)
    ]
    forbidden_runtime_patterns = (
        "firebase_admin",
        "db.reference(",
        "initialize_firebase(",
        "AUTHN_PROVIDER_MODE",
        "provider='firebase'",
        'provider = "firebase"',
        "firebase_uid",
        "from firebase_authz.service import",
    )
    findings = []
    for path in production_paths:
        source = path.read_text(encoding="utf-8")
        for pattern in forbidden_runtime_patterns:
            if pattern in source:
                findings.append(f"{path.relative_to(ROOT)} contains {pattern!r}")
        if path.parent.name == "firebase_authz" and "from .service import" in source:
            findings.append(f"{path.relative_to(ROOT)} imports the legacy service module")
        if "from firebase_authz import service" in source or "import firebase_authz.service" in source:
            findings.append(f"{path.relative_to(ROOT)} imports the legacy service module")
    assert not findings, "Active Firebase/RTDB production references remain: " + "; ".join(findings)


def test_production_dependencies_and_ci_do_not_configure_firebase_auth_or_emulator():
    requirements = (ROOT / "requirements.txt").read_text(encoding="utf-8")
    workflow = (ROOT / ".github" / "workflows" / "insightflow-backend-ci.yml").read_text(encoding="utf-8")
    excel_workflow = (ROOT / ".github" / "workflows" / "excel-addin-deploy.yml").read_text(encoding="utf-8")
    pubspec = (ROOT / "flutter_detail_source" / "pubspec.yaml").read_text(encoding="utf-8")
    lockfile = (ROOT / "flutter_detail_source" / "pubspec.lock").read_text(encoding="utf-8")
    assert "firebase-admin" not in requirements
    assert "firebase emulators:exec" not in workflow
    assert "npm run test:rules" not in workflow
    assert "INSIGHTFLOW_FIREBASE_WEB_" not in workflow
    assert "INSIGHTFLOW_FIREBASE_WEB_" not in excel_workflow
    assert not (ROOT / "firebase.json").exists()
    assert not (ROOT / "database.rules.json").exists()
    assert "firebase_auth:" not in pubspec
    assert "firebase_core:" not in pubspec
    assert "firebase_auth:" not in lockfile
    assert "firebase_core:" not in lockfile

    forbidden_flutter_patterns = (
        "package:firebase_auth/",
        "package:firebase_core/",
        "FirebaseAuth.instance",
        "Firebase.initializeApp",
        "FirebaseDatabase.instance",
    )
    flutter_root = ROOT / "flutter_detail_source" / "lib"
    findings = []
    for path in flutter_root.rglob("*.dart"):
        source = path.read_text(encoding="utf-8")
        for pattern in forbidden_flutter_patterns:
            if pattern in source:
                findings.append(f"{path.relative_to(ROOT)} contains {pattern!r}")
    assert not findings, "Firebase Auth/RTDB Flutter references remain: " + "; ".join(findings)


def test_active_auth_user_cleanup_migration_uses_only_supabase_subject():
    migration = (ROOT / "migrations" / "0032_supabase_only_auth_user_cleanup.sql").read_text(encoding="utf-8")
    assert "ib.provider = 'supabase'" in migration
    assert "ib.provider_subject = OLD.id::text" in migration
    assert "provider = 'firebase'" not in migration
    assert "firebase_uid" not in migration


def test_protected_api_path_fails_closed_when_bearer_is_missing(monkeypatch):
    import os
    from fastapi.testclient import TestClient
    from main import app

    monkeypatch.setenv("INSIGHTFLOW_AUTH_REQUIRED", "true")
    assert os.environ.get("INSIGHTFLOW_AUTH_REQUIRED", "").lower() == "true"
    response = TestClient(app).post("/smart_query", json={"query": "test"})
    assert response.status_code == 401
    assert response.json()["detail"] == "Supabase authentication required."
