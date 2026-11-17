BEGIN;
CREATE SCHEMA excel_handoff;
REVOKE ALL ON SCHEMA excel_handoff FROM PUBLIC, anon, authenticated;
CREATE TABLE excel_handoff.transactions (
    id uuid PRIMARY KEY,
    claim_digest bytea NOT NULL CHECK (octet_length(claim_digest) = 32),
    completion_digest bytea NOT NULL CHECK (octet_length(completion_digest) = 32),
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '3 minutes'),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'completed', 'claimed', 'cancelled')),
    ciphertext bytea,
    CHECK (claim_digest <> completion_digest)
);
CREATE INDEX excel_handoff_expiry ON excel_handoff.transactions (expires_at);
REVOKE ALL ON excel_handoff.transactions FROM PUBLIC, anon, authenticated;
ALTER TABLE excel_handoff.transactions ENABLE ROW LEVEL SECURITY;
COMMIT;
