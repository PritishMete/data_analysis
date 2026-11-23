"""Authenticated encryption and independent per-field protection for profile PII."""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes


class ProfileCryptoError(RuntimeError):
    """Profile PII cannot be safely encrypted or authenticated."""


def _master_key() -> bytes:
    raw = os.environ.get("INSIGHTFLOW_PROFILE_PII_KEY", "").strip()
    if not raw:
        raise ProfileCryptoError("INSIGHTFLOW_PROFILE_PII_KEY is required for profile PII.")
    try:
        key = bytes.fromhex(raw) if re.fullmatch(r"[0-9a-fA-F]{64}", raw) else base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    except Exception as exc:
        raise ProfileCryptoError("INSIGHTFLOW_PROFILE_PII_KEY must be a base64url or 64-character hex key.") from exc
    if len(key) != 32:
        raise ProfileCryptoError("INSIGHTFLOW_PROFILE_PII_KEY must decode to exactly 32 bytes.")
    return key


def _derive(master: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(master)


def _aad(field: str, organization_id: str, principal_id: str) -> bytes:
    if field not in {"phone", "id_proof"}:
        raise ProfileCryptoError("Unsupported profile PII field.")
    return f"insightflow:profile:{field}:v1:{organization_id}:{principal_id}".encode("utf-8")


def protect_profile_value(
    value: str,
    field: str,
    organization_id: str,
    principal_id: str,
    *,
    country_code: str | None = None,
    id_proof_type: str | None = None,
) -> dict[str, bytes | None]:
    plaintext = str(value or "").strip().encode("utf-8")
    if not plaintext:
        return {"ciphertext": None, "salt": None, "hmac": None, "fingerprint": None}
    master = _master_key()
    salt = secrets.token_bytes(32)
    aad = _aad(field, organization_id, principal_id)
    encryption_key = _derive(master, salt, b"InsightFlow/profile/" + field.encode() + b"/encryption/v1")
    digest_key = _derive(master, salt, b"InsightFlow/profile/" + field.encode() + b"/integrity/v1")
    nonce = secrets.token_bytes(12)
    ciphertext = nonce + AESGCM(encryption_key).encrypt(nonce, plaintext, aad)
    digest = hmac.new(digest_key, aad + b"\0" + plaintext, hashlib.sha256).digest()
    fingerprint = None
    if field == "id_proof":
        fingerprint = fingerprint_id_proof(
            plaintext.decode("utf-8"),
            organization_id,
            str(country_code or ""),
            str(id_proof_type or ""),
        )
    return {"ciphertext": ciphertext, "salt": salt, "hmac": digest, "fingerprint": fingerprint}


def reveal_profile_value(
    ciphertext: bytes | memoryview | None,
    salt: bytes | memoryview | None,
    digest: bytes | memoryview | None,
    field: str,
    organization_id: str,
    principal_id: str,
) -> str | None:
    if ciphertext is None and salt is None and digest is None:
        return None
    if ciphertext is None or salt is None or digest is None:
        raise ProfileCryptoError("Profile PII protection metadata is incomplete.")
    try:
        master = _master_key()
        salt_bytes = bytes(salt)
        ciphertext_bytes = bytes(ciphertext)
        aad = _aad(field, organization_id, principal_id)
        encryption_key = _derive(master, salt_bytes, b"InsightFlow/profile/" + field.encode() + b"/encryption/v1")
        digest_key = _derive(master, salt_bytes, b"InsightFlow/profile/" + field.encode() + b"/integrity/v1")
        nonce, encrypted = ciphertext_bytes[:12], ciphertext_bytes[12:]
        plaintext = AESGCM(encryption_key).decrypt(nonce, encrypted, aad)
        expected = hmac.new(digest_key, aad + b"\0" + plaintext, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, bytes(digest)):
            raise ProfileCryptoError("Profile PII integrity verification failed.")
        return plaintext.decode("utf-8")
    except ProfileCryptoError:
        raise
    except Exception as exc:
        raise ProfileCryptoError("Profile PII could not be decrypted or authenticated.") from exc


def fingerprint_id_proof(
    value: str,
    organization_id: str,
    country_code: str,
    id_proof_type: str,
) -> bytes:
    """Stable, keyed, organization-scoped token for duplicate-proof detection."""
    master = _master_key()
    context = f"{organization_id}:{country_code.upper()}:{id_proof_type.lower()}".encode("utf-8")
    key_salt = hashlib.sha256(context).digest()
    key = _derive(master, key_salt, b"InsightFlow/profile/id-proof/duplicate-fingerprint/v1")
    normalized = re.sub(r"[\s-]", "", str(value or "")).upper()
    return hmac.new(key, normalized.encode("utf-8"), hashlib.sha256).digest()


def verify_profile_pii_key() -> None:
    """Fail during backend startup if the trusted PII encryption key is absent or invalid."""
    _master_key()
