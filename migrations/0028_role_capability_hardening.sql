-- Align persisted role capabilities with the production hierarchy.
-- Managers and Team Leads can request working copies, but only Organization
-- Owners / Branch Heads may assign them. Invitation administration and audit
-- remain above the Manager level.
DELETE FROM role_permissions
WHERE role_id = 'manager'
  AND permission_id IN (
    'invitation.manage',
    'working_copy.assign',
    'audit.view',
    'roles.manage',
    'policies.manage'
  );

DELETE FROM role_permissions
WHERE role_id = 'team_lead'
  AND permission_id = 'working_copy.assign';

