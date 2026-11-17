import base64
import os
from uuid import uuid4

import pytest
from cryptography.exceptions import InvalidTag

from core.excel_handoff_crypto import handoff_cipher, seal_refresh_token, unseal_refresh_token


def test_ciphertext_bound_to_transaction(monkeypatch):
    monkeypatch.setenv("INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY", base64.urlsafe_b64encode(os.urandom(32)).decode())
    transaction = uuid4()
    sealed = seal_refresh_token(transaction, "test-only")
    assert unseal_refresh_token(transaction, sealed) == "test-only"
    with pytest.raises(InvalidTag):
        unseal_refresh_token(uuid4(), sealed)
    with pytest.raises(InvalidTag):
        unseal_refresh_token(transaction, sealed[:-1] + bytes([sealed[-1] ^ 1]))


@pytest.mark.parametrize("value", ["", "invalid", "YQ=="])
def test_key_fails_closed(monkeypatch, value):
    monkeypatch.setenv("INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY", value)
    with pytest.raises(RuntimeError):
        handoff_cipher()
