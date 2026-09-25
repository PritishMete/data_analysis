CREATE TABLE IF NOT EXISTS dataset_authorization (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    dataset_id TEXT NOT NULL,
    owner_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    protected_original BOOLEAN NOT NULL DEFAULT true,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, dataset_id),
    FOREIGN KEY (organization_id, dataset_id)
        REFERENCES authorization_resources(organization_id, resource_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS working_copy_authorization (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    working_copy_id TEXT NOT NULL,
    source_dataset_id TEXT NOT NULL,
    source_version TEXT NOT NULL DEFAULT '1',
    version INTEGER NOT NULL DEFAULT 1,
    created_by_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, working_copy_id)
);

ALTER TABLE dataset_authorization ENABLE ROW LEVEL SECURITY;
ALTER TABLE working_copy_authorization ENABLE ROW LEVEL SECURITY;
