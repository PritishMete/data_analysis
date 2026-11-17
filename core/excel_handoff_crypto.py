"""Authenticated encryption for pending Excel session handoffs."""

import base64
import os
from uuid import UUID

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def handoff_cipher() -> AESGCM:
    encoded = os.environ.get("INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY", "")
    try:
        key = base64.b64decode(encoded, altchars=b"-_", validate=True)
        if len(key) != 32 or base64.urlsafe_b64encode(key).decode() != encoded:
            raise ValueError
    except ValueError:
        raise RuntimeError("Excel browser authentication key is unavailable.") from None
    return AESGCM(key)


def seal_refresh_token(transaction: UUID, token: str) -> bytes:
    nonce = os.urandom(12)
    return nonce + handoff_cipher().encrypt(nonce, token.encode(), transaction.bytes)


def unseal_refresh_token(transaction: UUID, sealed: bytes) -> str:
    return handoff_cipher().decrypt(sealed[:12], sealed[12:], transaction.bytes).decode()
