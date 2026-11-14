INSERT INTO permissions(permission_id) VALUES
('data.view'),('analysis.run'),('worksheet.create'),('pivot.create'),
('worksheet.modify'),('worksheet.delete'),('operation.undo.own'),
('operation.undo.other'),('history.view'),('users.manage'),('roles.manage'),
('policies.manage'),('organization.view'),('organization.manage'),
('membership.view'),('membership.manage'),('dataset.upload'),
('dataset.view_original'),('dataset.create_working_copy'),
('dataset.edit_working_copy'),('dataset.delete'),('dataset.share'),
('dataset.manage_acl'),('working_copy.view'),('working_copy.modify'),
('working_copy.delete'),('audit.view'),('invitation.manage'),
('delegation.manage'),('account.delete'),('excel.mutate.original'),
('excel.mutate.working_copy')
ON CONFLICT (permission_id) DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'organization_owner', permission_id FROM permissions
ON CONFLICT (role_id, permission_id) DO NOTHING;

ALTER TABLE principals ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE approved_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE delegations ENABLE ROW LEVEL SECURITY;
ALTER TABLE authorization_resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
