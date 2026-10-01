-- Organization-scoped employee/person profiles.
-- Assignments remain responsible only for organizational placement/role.
-- Sensitive profile data is intentionally kept out of assignment list payloads.
CREATE TABLE IF NOT EXISTS organization_member_profiles (
    organization_id TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    full_name TEXT NOT NULL CHECK (char_length(full_name) BETWEEN 1 AND 160),
    email TEXT,
    email_verified_at TIMESTAMPTZ,
    phone_e164 TEXT,
    phone_verified_at TIMESTAMPTZ,
    address_line1 TEXT,
    address_line2 TEXT,
    city TEXT,
    state TEXT,
    postal_code TEXT,
    country TEXT,
    id_proof_type TEXT,
    id_proof_number TEXT,
    id_proof_provided_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, principal_id),
    CONSTRAINT fk_member_profile_member
        FOREIGN KEY (organization_id, principal_id)
        REFERENCES organization_members (organization_id, principal_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_member_profiles_org
    ON organization_member_profiles (organization_id);

CREATE INDEX IF NOT EXISTS idx_member_profiles_org_name
    ON organization_member_profiles (organization_id, lower(full_name));

CREATE INDEX IF NOT EXISTS idx_member_profiles_org_phone
    ON organization_member_profiles (organization_id, phone_e164);

ALTER TABLE organization_member_profiles ENABLE ROW LEVEL SECURITY;

-- Profiles are read/written by the trusted FastAPI management layer.
-- Do not expose this PII table through the Supabase Data API roles.
REVOKE ALL ON TABLE organization_member_profiles FROM PUBLIC;
REVOKE ALL ON TABLE organization_member_profiles FROM anon;
REVOKE ALL ON TABLE organization_member_profiles FROM authenticated;
