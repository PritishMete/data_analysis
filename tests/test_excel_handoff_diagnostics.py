from core.excel_handoff_diagnostics import (
    event,
    new_correlation_id,
    validate_correlation_id,
)


def test_handoff_diagnostics_allowlist_excludes_sensitive_values(caplog):
    correlation_id = new_correlation_id()
    with caplog.at_level("INFO"):
        event(
            "handoff_complete",
            correlation_id=correlation_id,
            success=False,
            status=401,
            exception_class="AuthenticationRequired",
            category="authentication_failure",
        )

    text = " ".join(record.getMessage() for record in caplog.records)
    assert correlation_id in text
    assert "handoff_complete" in text
    assert "AuthenticationRequired" in text
    assert "FAKE_ACCESS_TOKEN" not in text
    assert "FAKE_REFRESH_TOKEN" not in text
    assert "authorization" not in text.lower()


def test_correlation_ids_are_validated_without_becoming_authentication_proof():
    valid = new_correlation_id()
    assert validate_correlation_id(valid) == valid
    assert validate_correlation_id("auth-not-valid") != "auth-not-valid"
    assert validate_correlation_id(None) != ""
