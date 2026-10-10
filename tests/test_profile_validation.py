import pycountry
import pytest

from firebase_authz.profile_validation import (
    ProfileValidationError,
    normalize_id_proof_type,
    normalize_id_proof_number,
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


def test_country_without_iso_subdivisions_uses_explicit_not_applicable():
    country = next(
        item
        for item in pycountry.countries
        if not pycountry.subdivisions.get(country_code=item.alpha_2)
    )
    result = normalize_location(
        country_code=country.alpha_2,
        country=country.name,
        state_code="",
        state="",
    )
    assert result["country_code"] == country.alpha_2
    assert result["state_code"] == ""
    assert result["state"] == "Not applicable"


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
        phone="+919876543210",
        phone_country_calling_code="+91",
        phone_national_number="9876543210",
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
            phone="+919876543210",
            phone_country_calling_code="+91",
            phone_national_number="9876543210",
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


def test_id_proof_duplicate_normalization_ignores_case_spaces_and_hyphens():
    assert normalize_id_proof_number(" ab-c 123 ") == "ABC123"
    assert normalize_id_proof_number("ABC123") == "ABC123"
