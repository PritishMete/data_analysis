import pytest

from firebase_authz.profile_validation import (
    ProfileValidationError,
    normalize_id_proof_type,
    normalize_location,
    validate_profile_fields,
)


def test_country_state_consistency():
    result = normalize_location(
        country_code="IN",
        country="India",
        state_code="IN-WB",
        state="West Bengal",
    )
    assert result["country_code"] == "IN"
    assert result["state_code"] == "IN-WB"


def test_cross_country_state_is_rejected():
    with pytest.raises(ProfileValidationError):
        normalize_location(
            country_code="IN",
            country="India",
            state_code="US-CA",
            state="California",
        )


def test_required_profile_fields_and_optional_address2():
    fields = validate_profile_fields(
        full_name="Branch Head",
        country_code="IN",
        country="India",
        state_code="IN-WB",
        state="West Bengal",
        address_line1="1 Main Street",
        address_line2="",
        postal_code="700001",
        id_proof_type="pan",
        id_proof_number="ABCDE1234F",
        phone="+15551234567",
        phone_country_calling_code="+1",
        phone_national_number="5551234567",
    )
    assert fields["address_line2"] == ""

    with pytest.raises(ProfileValidationError):
        validate_profile_fields(
            full_name="Branch Head",
            country_code="IN",
            country="India",
            state_code="IN-WB",
            state="West Bengal",
            address_line1="",
            address_line2="",
            postal_code="700001",
            id_proof_type="pan",
            id_proof_number="ABCDE1234F",
            phone="+15551234567",
            phone_country_calling_code="+1",
            phone_national_number="5551234567",
        )


def test_international_postal_code():
    fields = validate_profile_fields(
        full_name="International",
        country_code="GB",
        country="United Kingdom",
        state_code="GB-ENG",
        state="England",
        address_line1="10 Example Street",
        address_line2=None,
        postal_code="SW1A 1AA",
        id_proof_type="passport",
        id_proof_number="X1234567",
        phone="+442079460018",
        phone_country_calling_code="+44",
        phone_national_number="2079460018",
    )
    assert fields["postal_code"] == "SW1A 1AA"


def test_country_aware_id_documents():
    assert normalize_id_proof_type("IN", "aadhaar") == "aadhaar"
    assert normalize_id_proof_type("US", "passport") == "passport"
    with pytest.raises(ProfileValidationError):
        normalize_id_proof_type("US", "aadhaar")
