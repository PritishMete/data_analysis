from __future__ import annotations

import pytest

from firebase_authz import profile_domain
from firebase_authz.service import AuthzError


class _Result:
    def __init__(self, *, row=None, scalar=None):
        self.row = row
        self.scalar = scalar

    def mappings(self):
        return self

    def first(self):
        return self.row

    def scalar_one_or_none(self):
        return self.scalar


class _FakeDB:
    def __init__(self, *, duplicate_phone=False, duplicate_id=False):
        self.duplicate_phone = duplicate_phone
        self.duplicate_id = duplicate_id
        self.identity_queries = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def execute(self, statement, params=None):
        sql = str(statement)
        if "SELECT phone_e164, phone_verified_at" in sql:
            return _Result(row={"phone_e164": "+14155552671", "phone_verified_at": None})
        if "WHERE phone_e164=:phone" in sql:
            self.identity_queries.append((sql, params))
            return _Result(scalar=1 if self.duplicate_phone else None)
        if "WHERE id_proof_type=:proof_type" in sql:
            self.identity_queries.append((sql, params))
            return _Result(scalar=1 if self.duplicate_id else None)
        raise AssertionError(f"Unexpected SQL in duplicate identity test: {sql}")


class _FakeSessionFactory:
    def __init__(self, db):
        self.db = db

    def begin(self):
        return self.db


@pytest.mark.parametrize(
    ("duplicate_phone", "duplicate_id", "expected_error"),
    [
        (True, False, "This phone number is already associated with another account."),
        (False, True, "This ID proof is already associated with another account."),
    ],
)
def test_profile_update_rejects_duplicate_identity(
    monkeypatch, duplicate_phone, duplicate_id, expected_error
):
    db = _FakeDB(duplicate_phone=duplicate_phone, duplicate_id=duplicate_id)
    monkeypatch.setattr(profile_domain, "SessionLocal", _FakeSessionFactory(db))
    monkeypatch.setattr(
        profile_domain,
        "_member",
        lambda *_args, **_kwargs: {
            "principal_id": "principal-current",
            "employee_id": "EMP-001",
            "organization_id": "org-1",
            "workspace_id": "workspace-1",
        },
    )
    monkeypatch.setattr(
        profile_domain,
        "validate_profile_fields",
        lambda **_kwargs: {
            "full_name": "Test User",
            "phone_e164": "+14155552671",
            "address_line1": "1 Test Street",
            "address_line2": "",
            "country_code": "US",
            "country": "United States",
            "state_code": "US-CA",
            "state": "California",
            "postal_code": "94105",
            "id_proof_type": "passport",
            "id_proof_number": "ab-123 45",
        },
    )

    with pytest.raises(AuthzError, match=expected_error):
        profile_domain.upsert_my_profile(
            {"sub": "supabase-user", "email": "test@example.com", "email_verified": True},
            "workspace-1",
            full_name="Test User",
            phone="+14155552671",
            phone_country_calling_code="+1",
            phone_national_number="4155552671",
            address_line1="1 Test Street",
            address_line2="",
            country_code="US",
            country="United States",
            state_code="US-CA",
            state="California",
            postal_code="94105",
            id_proof_type="passport",
            id_proof_number="ab-123 45",
        )

    assert db.identity_queries
    sql, params = db.identity_queries[-1]
    assert "principal_id<>:principal" in sql
    assert params["principal"] == "principal-current"
    if duplicate_id:
        assert "regexp_replace(upper(:proof_number)" in sql
