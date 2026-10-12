from firebase_authz.service import authenticated_identity


def test_supabase_identity_comes_only_from_verified_supabase_claims():
    identity = authenticated_identity(
        {
            "uid": "supabase-user-1",
            "sub": "supabase-user-1",
            "email": "employee@example.com",
            "email_verified": True,
            "name": "Employee",
            "provider": "supabase",
        }
    )
    assert identity["provider"] == "supabase"
    assert identity["provider_subject"] == "supabase-user-1"
    assert identity["auth_uid"] == "supabase-user-1"
    assert identity["verified_email"] == "employee@example.com"
    assert identity["display_name"] == "Employee"


def test_firebase_claims_cannot_select_or_override_auth_provider():
    identity = authenticated_identity(
        {
            "uid": "supabase-user-2",
            "sub": "supabase-user-2",
            "email": "employee@example.com",
            "firebase": {
                "sign_in_provider": "google.com",
                "identities": {"google.com": ["google-sub-2"]},
            },
        }
    )
    assert identity["provider"] == "supabase"
    assert identity["provider_subject"] == "supabase-user-2"
    assert identity["auth_uid"] == "supabase-user-2"
