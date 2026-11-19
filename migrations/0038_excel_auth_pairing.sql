BEGIN;

-- Additive extension of 0037. Existing v1 rows remain protocol_version=1 and
-- are rejected by the v2 API. No production database is changed by this file.
ALTER TABLE excel_handoff.transactions
  ADD COLUMN IF NOT EXISTS protocol_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS create_idempotency_digest bytea,
  ADD COLUMN IF NOT EXISTS generation integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS status_capability_digest bytea,
  ADD COLUMN IF NOT EXISTS approval_capability_digest bytea,
  ADD COLUMN IF NOT EXISTS cancel_capability_digest bytea,
  ADD COLUMN IF NOT EXISTS retry_capability_digest bytea,
  ADD COLUMN IF NOT EXISTS pairing_digest bytea,
  ADD COLUMN IF NOT EXISTS pairing_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS pairing_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS browser_capability_digest bytea,
  ADD COLUMN IF NOT EXISTS excel_instance_digest bytea,
  ADD COLUMN IF NOT EXISTS candidate_uid uuid,
  ADD COLUMN IF NOT EXISTS candidate_email text,
  ADD COLUMN IF NOT EXISTS candidate_generation integer,
  ADD COLUMN IF NOT EXISTS approved_uid uuid,
  ADD COLUMN IF NOT EXISTS approved_generation integer,
  ADD COLUMN IF NOT EXISTS candidate_request_id uuid,
  ADD COLUMN IF NOT EXISTS bind_request_id uuid,
  ADD COLUMN IF NOT EXISTS approval_request_id uuid,
  ADD COLUMN IF NOT EXISTS completion_request_id uuid,
  ADD COLUMN IF NOT EXISTS retry_request_id uuid,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_activity_at timestamptz NOT NULL DEFAULT clock_timestamp();

ALTER TABLE excel_handoff.transactions
  DROP CONSTRAINT IF EXISTS transactions_status_check;
ALTER TABLE excel_handoff.transactions
  ADD CONSTRAINT transactions_status_check CHECK (
    status IN ('pending','browser_bound','candidate_pending_approval',
      'approved','completed','claimed','rejected','cancelled','expired','failed')
  );
ALTER TABLE excel_handoff.transactions
  ADD CONSTRAINT excel_handoff_protocol_version_check CHECK (protocol_version IN (1,2)),
  ADD CONSTRAINT excel_handoff_generation_check CHECK (generation > 0),
  ADD CONSTRAINT excel_handoff_pairing_attempts_check CHECK (pairing_attempts BETWEEN 0 AND 5),
  ADD CONSTRAINT excel_handoff_capability_lengths_check CHECK (
    (create_idempotency_digest IS NULL OR octet_length(create_idempotency_digest)=32) AND
    (status_capability_digest IS NULL OR octet_length(status_capability_digest)=32) AND
    (approval_capability_digest IS NULL OR octet_length(approval_capability_digest)=32) AND
    (cancel_capability_digest IS NULL OR octet_length(cancel_capability_digest)=32) AND
    (retry_capability_digest IS NULL OR octet_length(retry_capability_digest)=32) AND
    (pairing_digest IS NULL OR octet_length(pairing_digest)=32) AND
    (browser_capability_digest IS NULL OR octet_length(browser_capability_digest)=32) AND
    (excel_instance_digest IS NULL OR octet_length(excel_instance_digest)=32)
  );

CREATE UNIQUE INDEX IF NOT EXISTS excel_handoff_create_idempotency_unique
  ON excel_handoff.transactions (create_idempotency_digest)
  WHERE protocol_version=2 AND create_idempotency_digest IS NOT NULL;
CREATE INDEX IF NOT EXISTS excel_handoff_v2_expiry
  ON excel_handoff.transactions (expires_at) WHERE protocol_version=2;
CREATE INDEX IF NOT EXISTS excel_handoff_v2_state
  ON excel_handoff.transactions (status, expires_at) WHERE protocol_version=2;

CREATE TABLE IF NOT EXISTS excel_handoff.create_rate_limits (
  id bigserial PRIMARY KEY,
  ip_digest bytea NOT NULL CHECK (octet_length(ip_digest)=32),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS excel_handoff_create_rate_window
  ON excel_handoff.create_rate_limits (ip_digest, created_at);

REVOKE ALL ON SCHEMA excel_handoff FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA excel_handoff FROM PUBLIC, anon, authenticated;
ALTER TABLE excel_handoff.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE excel_handoff.create_rate_limits ENABLE ROW LEVEL SECURITY;

COMMIT;
