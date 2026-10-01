"""Backend authority for ISO profile geography, phone, postal, and ID validation."""
from __future__ import annotations

import re
from functools import lru_cache
from typing import Any

import phonenumbers
import pycountry


class ProfileValidationError(ValueError):
    """A submitted profile value or relationship is invalid."""


GLOBAL_ID_PROOF_TYPES = {
    "national_id": "National ID / National Identity Card",
    "passport": "Passport",
    "driving_license": "Driving Licence",
    "other_government_id": "Other Government ID",
}

INDIA_ID_PROOF_TYPES = {
    **GLOBAL_ID_PROOF_TYPES,
    "aadhaar": "Aadhaar",
    "pan": "PAN",
    "voter_id": "Voter ID",
}


def _clean(value: Any, field: str, limit: int, required: bool = True) -> str:
    value = str(value or "").strip()
    if required and not value:
        raise ProfileValidationError(f"{field} is required.")
    if len(value) > limit:
        raise ProfileValidationError(f"{field} must be at most {limit} characters.")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ProfileValidationError(f"{field} contains invalid control characters.")
    return value


@lru_cache(maxsize=1)
def _countries() -> tuple[Any, ...]:
    return tuple(pycountry.countries)


def country_from_input(country_code: str | None) -> Any:
    code = str(country_code or "").strip().upper()
    if not re.fullmatch(r"[A-Z]{2}", code):
        raise ProfileValidationError("Country code must be an ISO 3166-1 alpha-2 code.")
    for item in _countries():
        if str(getattr(item, "alpha_2", "")).upper() == code:
            return item
    raise ProfileValidationError("Selected country is not a supported ISO country.")


@lru_cache(maxsize=4096)
def subdivision_by_code(state_code: str) -> Any | None:
    code = str(state_code or "").strip().upper()
    if not re.fullmatch(r"[A-Z]{2,3}-[A-Z0-9.-]{1,8}", code):
        return None
    return pycountry.subdivisions.get(code=code)


def normalize_location(
    *,
    country_code: str | None,
    state_code: str | None,
    country: str | None = None,
    state: str | None = None,
) -> dict[str, str]:
    country_obj = country_from_input(country_code)
    subdivision = subdivision_by_code(str(state_code or ""))
    if (
        subdivision is None
        or str(getattr(subdivision, "country_code", "")).upper()
        != str(country_obj.alpha_2).upper()
    ):
        raise ProfileValidationError(
            "Selected state/province/region does not belong to the selected country."
        )

    return {
        "country_code": str(country_obj.alpha_2).upper(),
        "country": str(country_obj.name),
        "state_code": str(subdivision.code).upper(),
        "state": str(subdivision.name),
    }


def normalize_phone_submission(
    phone: str,
    *,
    calling_code: str | None = None,
    national_number: str | None = None,
) -> str:
    raw = re.sub(r"[\s().-]", "", str(phone or "").strip())
    if not raw.startswith("+"):
        raise ProfileValidationError(
            "Phone number must be supplied as an international number."
        )

    try:
        parsed = phonenumbers.parse(raw, None)
    except phonenumbers.NumberParseException as exc:
        raise ProfileValidationError("Phone number is not valid.") from exc

    if not phonenumbers.is_valid_number(parsed):
        raise ProfileValidationError("Phone number is not a valid international number.")

    normalized = phonenumbers.format_number(
        parsed,
        phonenumbers.PhoneNumberFormat.E164,
    )

    if calling_code is not None:
        cc = re.sub(r"[\s()-]", "", str(calling_code).strip())
        if not re.fullmatch(r"\+[1-9]\d{0,3}", cc):
            raise ProfileValidationError("Phone country calling code is invalid.")
        if int(cc[1:]) != phonenumbers.country_code_for_number(parsed):
            raise ProfileValidationError(
                "Phone number does not match the selected country calling code."
            )

    if national_number is not None:
        national = re.sub(r"\s+", "", str(national_number).strip())
        if not re.fullmatch(r"\d{4,15}", national):
            raise ProfileValidationError(
                "National phone number must contain 4 to 15 digits."
            )
        if calling_code is None:
            raise ProfileValidationError("Phone country calling code is required.")

        try:
            component = phonenumbers.parse(
                str(calling_code).strip() + national,
                None,
            )
        except phonenumbers.NumberParseException as exc:
            raise ProfileValidationError(
                "Phone number components could not be combined."
            ) from exc

        if not phonenumbers.is_valid_number(component):
            raise ProfileValidationError(
                "Phone number components do not form a valid number."
            )

        component_normalized = phonenumbers.format_number(
            component,
            phonenumbers.PhoneNumberFormat.E164,
        )
        if component_normalized != normalized:
            raise ProfileValidationError(
                "Phone number components do not match the submitted phone."
            )

    return normalized


def validate_postal_code(value: str) -> str:
    postal = _clean(value, "PIN / Postal Code", 24)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 -]{0,23}", postal):
        raise ProfileValidationError("PIN / Postal Code contains an invalid format.")
    return postal


def normalize_id_proof_type(country_code: str, value: str) -> str:
    code = str(country_code or "").strip().upper()
    country_from_input(code)
    options = INDIA_ID_PROOF_TYPES if code == "IN" else GLOBAL_ID_PROOF_TYPES

    key = str(value or "").strip().casefold().replace(" ", "_")
    aliases = {
        "driving_licence": "driving_license",
        "voter": "voter_id",
        "voterid": "voter_id",
        "national_id_card": "national_id",
        "other": "other_government_id",
    }
    key = aliases.get(key, key)

    if key not in options:
        raise ProfileValidationError(
            "ID Proof Type is not allowed for the selected country."
        )
    return key


def validate_profile_fields(
    *,
    full_name: str,
    country_code: str | None,
    country: str | None,
    state_code: str | None,
    state: str | None,
    address_line1: str,
    address_line2: str | None,
    postal_code: str,
    id_proof_type: str,
    id_proof_number: str,
    phone: str,
    phone_country_calling_code: str | None,
    phone_national_number: str | None,
) -> dict[str, str]:
    name = _clean(full_name, "Full Name", 160)
    location = normalize_location(
        country_code=country_code,
        state_code=state_code,
        country=country,
        state=state,
    )

    return {
        **location,
        "full_name": name,
        "phone_e164": normalize_phone_submission(
            phone,
            calling_code=phone_country_calling_code,
            national_number=phone_national_number,
        ),
        "address_line1": _clean(address_line1, "Address Line 1", 240),
        "address_line2": _clean(
            address_line2,
            "Address Line 2",
            240,
            required=False,
        ),
        "postal_code": validate_postal_code(postal_code),
        "id_proof_type": normalize_id_proof_type(
            location["country_code"],
            id_proof_type,
        ),
        "id_proof_number": _clean(
            id_proof_number,
            "ID Proof Number",
            160,
        ),
    }
