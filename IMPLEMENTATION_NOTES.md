# Gmail OAuth hardening implementation notes

- OAuth state remains HMAC-signed and expires after ten minutes. Its cryptographically random nonce is stored only as a SHA-256 hash in `gmail_oauth_states`.
- The callback revalidates the initiating principal's branch authorization, then atomically deletes the matching unexpired state row with a single `DELETE ... RETURNING` before exchanging the Google authorization code. Concurrent callbacks cannot both consume one row.
- The migration is discovered by `tools/run_authz_migrations.py` through its existing sorted `migrations/[0-9][0-9][0-9][0-9]_*.sql` glob. It has not been applied to any database.
- Reconnecting Gmail refreshes the connected account and encrypted refresh token without overwriting the existing display name or selected Send-As address. The selected address is still checked against Gmail's Send-As list and must be primary or verified/accepted.
- The connected Gmail account address (`sender_email`), actual Send-As address (`sender_identity`), and display identity (`sender_name`) remain separate fields. The display identity is used only as the MIME From display name, never as authorization to send from an address.
- No production deployment, production migration, or real email send was performed.

Validation is pending until the repository's focused and backend CI tests run in an executable checkout.
