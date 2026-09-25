ALTER TABLE identity_bindings ADD COLUMN IF NOT EXISTS firebase_uid TEXT;
CREATE INDEX IF NOT EXISTS idx_identity_bindings_firebase_uid ON identity_bindings(firebase_uid);
