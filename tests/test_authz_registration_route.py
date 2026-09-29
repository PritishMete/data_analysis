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
        },
    )

    def reject_duplicate(claims, organization_name, branch_name, branch_identifier):
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
