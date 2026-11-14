-- Remove the generic employee role from the production role model.
-- Existing generic employee assignments are preserved as Data Analyst so no
-- member loses access when the role is removed. Employee IDs remain unchanged.

DELETE FROM member_roles mr
WHERE mr.role_id = 'employee'
  AND EXISTS (
    SELECT 1
    FROM member_roles existing
    WHERE existing.organization_id = mr.organization_id
      AND existing.principal_id = mr.principal_id
      AND existing.role_id = 'data_analyst'
  );

UPDATE member_roles
SET role_id = 'data_analyst'
WHERE role_id = 'employee';

UPDATE organizational_assignments
SET role_id = 'data_analyst'
WHERE role_id = 'employee';

UPDATE invitations
SET role_id = 'data_analyst'
WHERE role_id = 'employee';

DELETE FROM role_permissions
WHERE role_id = 'employee';

DELETE FROM roles
WHERE role_id = 'employee';
