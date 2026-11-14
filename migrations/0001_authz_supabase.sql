CREATE TABLE IF NOT EXISTS principals (
    principal_id TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS identity_bindings (
    provider TEXT NOT NULL,
    provider_subject TEXT NOT NULL,
    principal_id TEXT NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, provider_subject)
);

CREATE TABLE IF NOT EXISTS organizations (
    organization_id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    status TEXT NOT NULL DEFAULT 'active',
    created_by_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS workspaces (
    workspace_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL UNIQUE REFERENCES organizations(organization_id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS organization_members (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
    principal_id TEXT NOT NULL REFERENCES principals(principal_id),
    employee_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, principal_id),
    UNIQUE (workspace_id, employee_id)
);

CREATE TABLE IF NOT EXISTS roles (
    role_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS permissions (
    permission_id TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id TEXT NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    permission_id TEXT NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS member_roles (
    organization_id TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    role_id TEXT NOT NULL REFERENCES roles(role_id),
    PRIMARY KEY (organization_id, principal_id, role_id),
    FOREIGN KEY (organization_id, principal_id)
        REFERENCES organization_members(organization_id, principal_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS invitations (
    invitation_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    role_id TEXT NOT NULL REFERENCES roles(role_id),
    status TEXT NOT NULL DEFAULT 'invited',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS approved_employees (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    employee_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'approved',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, employee_id)
);

CREATE TABLE IF NOT EXISTS delegations (
    delegation_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    team_lead_principal_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS authorization_resources (
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    resource_id TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    owner_principal_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, resource_id)
);

CREATE TABLE IF NOT EXISTS audit_events (
    event_id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    actor_principal_id TEXT,
    action TEXT NOT NULL,
    outcome TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO roles(role_id, name) VALUES
    ('organization_owner', 'Organization Owner'), ('manager', 'Manager'),
    ('team_lead', 'Team Lead'), ('employee', 'Employee'),
    ('external_viewer', 'External Viewer')
ON CONFLICT (role_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_identity_bindings_principal ON identity_bindings(principal_id);
CREATE INDEX IF NOT EXISTS idx_members_workspace ON organization_members(workspace_id);
CREATE INDEX IF NOT EXISTS idx_members_principal ON organization_members(principal_id);
