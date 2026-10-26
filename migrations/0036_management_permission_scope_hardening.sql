-- Tighten legacy management capabilities and expose only scoped Manager actions.
-- Managers may create sections and request Team Lead assignments inside their
-- assigned branch, but do not receive user/profile administration authority.
INSERT INTO permissions(permission_id)
VALUES ('organization.section.create'), ('team_lead.request')
ON CONFLICT (permission_id) DO NOTHING;

DELETE FROM role_permissions
WHERE role_id = 'manager'
  AND permission_id IN (
    'users.manage',
    'membership.manage',
    'invitation.manage',
    'audit.view',
    'delegation.manage',
    'roles.manage',
    'policies.manage',
    'working_copy.assign'
  );

INSERT INTO role_permissions(role_id, permission_id)
VALUES
    ('manager', 'organization.section.create'),
    ('manager', 'team_lead.request')
ON CONFLICT (role_id, permission_id) DO NOTHING;
