-- InsightFlow organizational structure foundation.
-- Additive only: existing auth/RBAC/workspace tables remain intact.
--
-- Model:
--   organization -> locations / sections
--   principal -> organizational_assignments
-- An assignment represents a person's role in an organizational context.
-- The same principal may therefore have multiple assignments, including
-- multiple Team Lead assignments across sections, without duplicating the person.

CREATE TABLE IF NOT EXISTS locations (
    location_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL
        REFERENCES organizations(organization_id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, location_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_locations_active_name
    ON locations (organization_id, lower(name))
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_locations_organization_status
    ON locations (organization_id, status);

CREATE TABLE IF NOT EXISTS sections (
    section_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL
        REFERENCES organizations(organization_id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organization_id, section_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sections_active_name
    ON sections (organization_id, lower(name))
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_sections_organization_status
    ON sections (organization_id, status);

CREATE TABLE IF NOT EXISTS organizational_assignments (
    assignment_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL
        REFERENCES organizations(organization_id) ON DELETE CASCADE,
    principal_id TEXT NOT NULL
        REFERENCES principals(principal_id) ON DELETE CASCADE,
    location_id TEXT,
    role_id TEXT NOT NULL
        REFERENCES roles(role_id),
    section_id TEXT,
    reports_to_assignment_id TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A location must belong to this same organization.
    CONSTRAINT fk_assignment_location_same_org
        FOREIGN KEY (organization_id, location_id)
        REFERENCES locations(organization_id, location_id),

    -- A section must belong to this same organization.
    CONSTRAINT fk_assignment_section_same_org
        FOREIGN KEY (organization_id, section_id)
        REFERENCES sections(organization_id, section_id),

    -- A reporting assignment must belong to this same organization.
    CONSTRAINT fk_assignment_parent_same_org
        FOREIGN KEY (organization_id, reports_to_assignment_id)
        REFERENCES organizational_assignments(organization_id, assignment_id)
);

CREATE INDEX IF NOT EXISTS idx_assignments_org_status
    ON organizational_assignments(organization_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_principal_status
    ON organizational_assignments(principal_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_location_status
    ON organizational_assignments(organization_id, location_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_section_status
    ON organizational_assignments(organization_id, section_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_parent_status
    ON organizational_assignments(organization_id, reports_to_assignment_id, status);

-- Exactly one active Manager per location.
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_manager_per_location
    ON organizational_assignments(organization_id, location_id)
    WHERE role_id = 'manager'
      AND status = 'active'
      AND location_id IS NOT NULL;

-- Do not create duplicate active assignments for the same person/context.
-- COALESCE permits company-level assignments (NULL location/section/parent)
-- while still making the combination unique.
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_assignment_context
    ON organizational_assignments (
        organization_id,
        principal_id,
        role_id,
        COALESCE(location_id, ''),
        COALESCE(section_id, ''),
        COALESCE(reports_to_assignment_id, '')
    )
    WHERE status = 'active';

ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizational_assignments ENABLE ROW LEVEL SECURITY;
