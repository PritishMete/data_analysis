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
    from_header = next(
        line.decode("utf-8") for line in raw.split(b"\n") if line.lower().startswith(b"from:")
    )

    assert from_header.startswith("From:")
    assert "insightflow@tcs.kolkata" in from_header
    assert "<tcscorp@gmail.com>" in from_header
    assert from_header.count("@") == 2
    assert message["To"] == "employee@example.com"


def test_management_route_imports_gmail_connection_errors():
    import firebase_authz.management_routes as routes

    assert routes.GmailConfigurationError.__name__ == "GmailConfigurationError"
    assert routes.GmailConnectionError.__name__ == "GmailConnectionError"


def test_flutter_web_preflight_is_allowed():
    from fastapi.testclient import TestClient
    from main import app

    client = TestClient(app)
    response = client.options(
        "/v1/authz/management/email-settings/connect?location_id=loc_main",
        headers={
            "Origin": "https://pritishmete.github.io",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,x-insightflow-workspace-id",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "https://pritishmete.github.io"
