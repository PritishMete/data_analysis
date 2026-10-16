from firebase_authz.service import authenticated_identity


def test_microsoft_provider_identity_comes_from_verified_firebase_claims():
    identity = authenticated_identity(
        {
            "uid": "firebase-user-1",
            "email": "employee@example.com",
            "email_verified": True,
            "name": "Employee",
            "firebase": {
                "sign_in_provider": "microsoft.com",
                "identities": {"microsoft.com": ["microsoft-sub-1"]},
            },
        }
    )

    assert identity["provider"] == "microsoft.com"
    assert identity["provider_subject"] == "microsoft-sub-1"
    assert identity["firebase_uid"] == "firebase-user-1"
    assert identity["verified_email"] == "employee@example.com"
    assert identity["display_name"] == "Employee"


def test_google_provider_identity_uses_verified_google_subject():
    identity = authenticated_identity(
        {
            "uid": "firebase-user-2",
            "email": "google@example.com",
            "email_verified": True,
            "name": "Google User",
            "firebase": {
                "sign_in_provider": "google.com",
                "identities": {"google.com": ["google-sub-2"]},
            },
        }
    )

    assert identity["provider"] == "google.com"
    assert identity["provider_subject"] == "google-sub-2"
    assert identity["firebase_uid"] == "firebase-user-2"
