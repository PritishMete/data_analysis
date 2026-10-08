def test_invitation_sender_uses_gmail_scope():
    from firebase_authz.gmail_invitation_email import GMAIL_SCOPE
    assert GMAIL_SCOPE == "https://www.googleapis.com/auth/gmail.send"


def test_new_invitation_source_keeps_auth_user_null():
    import inspect
    from firebase_authz.supabase_provider import create_invitation
    source = inspect.getsource(create_invitation)
    assert "auth_user_id, location_id" in source
    assert "VALUES (:id,:org,:email,:employee,:role,'invited',:expires,:creator,NULL,:location" in source
