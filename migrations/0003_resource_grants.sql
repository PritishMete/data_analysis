CREATE TABLE IF NOT EXISTS resource_grants (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    resource_id TEXT NOT NULL,
    principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
    permissions JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, resource_id, principal_id),
    FOREIGN KEY (organization_id, resource_id)
        REFERENCES authorization_resources(organization_id, resource_id) ON DELETE CASCADE
);
ALTER TABLE resource_grants ENABLE ROW LEVEL SECURITY;
