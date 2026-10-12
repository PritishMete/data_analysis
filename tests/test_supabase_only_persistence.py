from __future__ import annotations

from pathlib import Path

import pytest

from firebase_authz import management_domain, supabase_provider


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
        supabase_provider._identity({"email": "employee@example.com"})


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
