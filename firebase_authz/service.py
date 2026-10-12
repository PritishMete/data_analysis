"""Compatibility exports for Supabase authentication errors and helpers.

Authorization persistence is implemented exclusively by PostgreSQL repositories
in `supabase_provider`. The retired Firebase Auth/RTDB service implementation
has been removed from the application and test suite.
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
