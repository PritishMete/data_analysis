-- InsightFlow organizational hierarchy foundation.
-- Additive migration: Company -> Location -> Section -> role assignments.
-- Authentication answers who is signed in; these tables answer where/what role.

CREATE TABLE IF NOT EXISTS locations (
    location_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_locations_active_name
    ON locations (organization_id, lower(name))
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_locations_org_status
    ON locations (organization_id, status);

CREATE TABLE IF NOT EXISTS sections (
    section_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    location_id TEXT NOT NULL REFERENCES locations(location_id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, section_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sections_active_name
    ON sections (organization_id, location_id, lower(name))
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sections_org_location_status
    ON sections (organization_id, location_id, status);

CREATE TABLE IF NOT EXISTS organizational_assignments (
    assignment_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
    location_id TEXT,
    role_id TEXT NOT NULL REFERENCES roles(role_id),
    section_id TEXT,
    reports_to_assignment_id TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_assignment_location_same_org
        FOREIGN KEY (organization_id, location_id)
        REFERENCES locations (organization_id, location_id)
        DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT fk_assignment_section_same_org
        FOREIGN KEY (organization_id, section_id)
        REFERENCES sections (organization_id, section_id)
        DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT fk_assignment_parent
        FOREIGN KEY (reports_to_assignment_id)
        REFERENCES organizational_assignments(assignment_id)
        ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_assignments_org_status
    ON organizational_assignments (organization_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_principal_status
    ON organizational_assignments (principal_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_location_status
    ON organizational_assignments (location_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_section_status
    ON organizational_assignments (section_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_parent_status
    ON organizational_assignments (reports_to_assignment_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS uq_active_manager_per_location
    ON organizational_assignments (organization_id, location_id)
    WHERE status = 'active' AND role_id = 'manager' AND location_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_active_assignment_context
    ON organizational_assignments (
        organization_id,
        principal_id,
        COALESCE(location_id, ''),
        COALESCE(section_id, ''),
        role_id
    )
    WHERE status = 'active';

ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizational_assignments ENABLE ROW LEVEL SECURITY;

-- The backend uses the trusted Supabase connection for these tables and
-- enforces company/location/role authorization server-side. No client policy
-- is added here that could bypass the application authorization layer.
