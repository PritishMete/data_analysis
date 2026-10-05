-- Manager-to-Branch-Head approval workflow for Team Lead assignments.
CREATE TABLE IF NOT EXISTS management_assignment_requests (
    request_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
    requester_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    location_id TEXT NOT NULL REFERENCES locations(location_id),
    section_id TEXT NOT NULL REFERENCES sections(section_id),
    target_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    requested_role TEXT NOT NULL DEFAULT 'team_lead'
        CHECK (requested_role = 'team_lead'),
    reports_to_assignment_id TEXT REFERENCES organizational_assignments(assignment_id),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','approved','rejected','cancelled')),
    reviewed_by_principal_id TEXT REFERENCES principals(principal_id),
    reviewed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_management_assignment_requests_scope
 ON management_assignment_requests(organization_id, location_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_management_assignment_requests_requester
 ON management_assignment_requests(organization_id, requester_principal_id, status);
ALTER TABLE management_assignment_requests ENABLE ROW LEVEL SECURITY;
