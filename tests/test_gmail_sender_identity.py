def test_sender_identity_normalization():
    from firebase_authz.gmail_invitation_email import generate_sender_identity

    assert generate_sender_identity("TCS Limited", "New Town Kolkata") == "insightflow@tcs-limited.new-town-kolkata"
    assert generate_sender_identity("ABC Analytics", "Singur") == "insightflow@abc-analytics.singur"


def test_invitation_keeps_transport_gmail_separate_from_generated_identity(monkeypatch):
    import base64
    from email import policy
    from email.parser import BytesParser
    import firebase_authz.gmail_invitation_email as gmail

    monkeypatch.setattr(
        gmail,
        "_connection",
        lambda *_: (
            "Configured sender",
            "tcscorp@gmail.com",
            "encrypted-refresh",
        ),
    )
    monkeypatch.setattr(gmail, "_refresh_access_token", lambda _: "access-token")
    monkeypatch.setattr(
        gmail,
        "_company_sender_settings",
        lambda *_: {"sender_identity": "insightflow@tcs.kolkata"},
    )
    captured = {}

    def fake_send(url, access_token, body):
        captured["raw"] = body["raw"]
        return {"id": "message-1"}

    monkeypatch.setattr(gmail, "_gmail_json", fake_send)

    gmail.send_invitation_email(
        recipient="employee@example.com",
        organization_name="TCS",
        role_id="data_analyst",
        invitation_url="https://example.com/invite",
        expires_at=None,
        workspace_id="org_test",
        location_id="loc_main",
    )

    padding = "=" * ((4 - len(captured["raw"]) % 4) % 4)
    raw = base64.urlsafe_b64decode(captured["raw"] + padding)
    message = BytesParser(policy=policy.default).parsebytes(raw)

    assert message["From"] == "InsightFlow • insightflow@tcs.kolkata <tcscorp@gmail.com>"
    assert "insightflow@tcs.kolkata" in message["From"]
    assert "tcscorp@gmail.com" in message["From"]
