import pytest
from fastapi import HTTPException

from firebase_authz import routes


def test_founder_registration_maps_authorization_conflict_to_403(monkeypatch):
    from firebase_authz.service import AuthzError

    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        "firebase_authz.supabase_auth.verify_supabase_access_token",
        lambda token, require_email_verified=True: {
            "uid": "duplicate-route-user",
            "sub": "duplicate-route-user",
            "email": "duplicate@example.com",
            "email_verified": True,
            "email_confirmed_at": "2026-10-01T00:00:00Z",
            "phone": "+15551234567",
            "phone_confirmed_at": "2026-10-01T00:00:00Z",
        },
    )

    def reject_duplicate(claims, organization_name, branch_name, branch_identifier, **kwargs):
        raise AuthzError(
            "This account already has an active organization membership."
        )

    monkeypatch.setattr(
        "firebase_authz.supabase_provider.register_organization",
        reject_duplicate,
    )

    with pytest.raises(HTTPException) as exc_info:
        routes.founder_organization_register(
            routes.FounderOrganizationRegistration(
                organization_name="Second Organization",
                branch_name="Second Branch",
                branch_identifier="SECOND-ORG",
                employee_id="EMP002",
                full_name="Duplicate Route User",
                phone="+15551234567",
                phone_country_calling_code="+1",
                phone_national_number="5551234567",
                address_line1="1 Route Way",
                state="California",
                state_code="US-CA",
                postal_code="90210",
                country="United States",
                country_code="US",
                id_proof_type="passport",
                id_proof_number="TEST-002",
            ),
            authorization="Bearer test-token",
        )

    assert exc_info.value.status_code == 403
    assert "active organization membership" in str(exc_info.value.detail)


def test_founder_registration_keeps_validation_errors_as_400(monkeypatch):
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        "firebase_authz.supabase_auth.verify_supabase_access_token",
        lambda token, require_email_verified=True: {
            "uid": "validation-route-user",
            "sub": "validation-route-user",
            "email": "validation@example.com",
        },
    )

    with pytest.raises(HTTPException) as exc_info:
        routes.founder_organization_register(
            routes.FounderOrganizationRegistration(
                organization_name=None,
                branch_name="Main Branch",
                branch_identifier="MAIN-01",
            ),
            authorization="Bearer test-token",
        )

    assert exc_info.value.status_code == 400



def test_founder_registration_rejects_unverified_phone_before_provider_registration(monkeypatch):
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER", "supabase")
    monkeypatch.setattr(
        "firebase_authz.supabase_auth.verify_supabase_access_token",
        lambda token, require_email_verified=True: {
            "uid": "phone-route-user",
            "sub": "phone-route-user",
            "email": "phone@example.com",
            "email_verified": True,
            "phone": "+15551234567",
            "phone_confirmed_at": None,
        },
    )
    called = False

    def fail_if_called(*args, **kwargs):
        nonlocal called
        called = True
        raise AssertionError("registration provider must not be called")

    monkeypatch.setattr(
        "firebase_authz.supabase_provider.register_organization",
        fail_if_called,
    )

    with pytest.raises(HTTPException) as exc_info:
        routes.founder_organization_register(
            routes.FounderOrganizationRegistration(
                organization_name="Phone Company",
                branch_name="Main Branch",
                branch_identifier="PHONE-ORG",
                employee_id="EMP001",
                full_name="Phone User",
                phone="+15551234567",
                phone_country_calling_code="+1",
                phone_national_number="5551234567",
                address_line1="1 Phone Way",
                state="California",
                state_code="US-CA",
                postal_code="90210",
                country="United States",
                country_code="US",
                id_proof_type="passport",
                id_proof_number="TEST-PHONE",
            ),
            authorization="Bearer test-token",
        )

    assert exc_info.value.status_code == 403
    assert "verified phone" in str(exc_info.value.detail)
    assert called is False


def test_founder_registration_forbids_authz_identity_fields():
    with pytest.raises(ValueError):
        routes.FounderOrganizationRegistration(
            organization_name="Company",
            branch_name="Branch",
            branch_identifier="BRANCH-1",
            organization_id="forbidden",
        )
