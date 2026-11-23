import base64

import pytest

from firebase_authz.profile_crypto import (
    ProfileCryptoError,
    protect_profile_value,
    reveal_profile_value,
)


TEST_KEY = "0" * 64


def test_phone_and_id_proof_use_independent_random_salts_and_round_trip(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_PROFILE_PII_KEY", TEST_KEY)
    phone = protect_profile_value("+919876543210", "phone", "org-a", "user-a")
    proof = protect_profile_value(
        "AB1234567", "id_proof", "org-a", "user-a",
        country_code="IN", id_proof_type="passport",
    )
    assert phone["salt"] != proof["salt"]
    assert len(phone["salt"]) == 32
    assert len(proof["salt"]) == 32
    assert reveal_profile_value(
        phone["ciphertext"], phone["salt"], phone["hmac"],
        "phone", "org-a", "user-a",
    ) == "+919876543210"
    assert reveal_profile_value(
        proof["ciphertext"], proof["salt"], proof["hmac"],
        "id_proof", "org-a", "user-a",
    ) == "AB1234567"


def test_salts_are_fresh_for_each_user_and_each_update(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_PROFILE_PII_KEY", TEST_KEY)
    first = protect_profile_value("+919876543210", "phone", "org-a", "user-a")
    second = protect_profile_value("+919876543210", "phone", "org-a", "user-b")
    update = protect_profile_value("+919876543210", "phone", "org-a", "user-a")
    assert len({first["salt"], second["salt"], update["salt"]}) == 3
    assert len({first["ciphertext"], second["ciphertext"], update["ciphertext"]}) == 3


def test_id_proof_fingerprint_is_stable_only_within_organization_context(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_PROFILE_PII_KEY", TEST_KEY)
    first = protect_profile_value(
        "ab-123 4567", "id_proof", "org-a", "user-a",
        country_code="IN", id_proof_type="passport",
    )
    second = protect_profile_value(
        "AB1234567", "id_proof", "org-a", "user-b",
        country_code="IN", id_proof_type="passport",
    )
    other_org = protect_profile_value(
        "AB1234567", "id_proof", "org-b", "user-c",
        country_code="IN", id_proof_type="passport",
    )
    assert first["fingerprint"] == second["fingerprint"]
    assert first["fingerprint"] != other_org["fingerprint"]


def test_integrity_failure_rejects_modified_ciphertext(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_PROFILE_PII_KEY", TEST_KEY)
    value = protect_profile_value("+919876543210", "phone", "org-a", "user-a")
    altered = bytearray(value["ciphertext"])
    altered[-1] ^= 1
    with pytest.raises(ProfileCryptoError):
        reveal_profile_value(
            bytes(altered), value["salt"], value["hmac"],
            "phone", "org-a", "user-a",
        )


def test_missing_profile_key_fails_closed(monkeypatch):
    monkeypatch.delenv("INSIGHTFLOW_PROFILE_PII_KEY", raising=False)
    with pytest.raises(ProfileCryptoError):
        protect_profile_value("+919876543210", "phone", "org-a", "user-a")
