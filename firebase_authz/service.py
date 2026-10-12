"""Compatibility exports for Supabase authentication errors and helpers.

Authorization persistence is implemented exclusively by PostgreSQL repositories
in `supabase_provider`. The retired RTDB implementation has been moved to
`tests/fixtures/legacy_rtdb_service.py` and is not part of the application.
"""
from .auth import (
    AuthzError,
    AuthenticationRequired,
    EmailVerificationRequired,
    PermissionDenied,
    BootstrapDenied,
    verify_id_token,
    authenticated_identity,
    require_email_verified,
)
