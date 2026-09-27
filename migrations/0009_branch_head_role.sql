-- InsightFlow branch-head registration role.
-- The first authenticated registrant owns the newly created branch.
-- Branch scope is enforced by organizational assignments; this role is
-- intentionally separate from the legacy organization_owner role.

INSERT INTO roles(role_id, name)
VALUES ('branch_head', 'Branch Head')
ON CONFLICT (role_id) DO NOTHING;

INSERT INTO role_permissions(role_id, permission_id)
SELECT 'branch_head', permission_id
FROM permissions
ON CONFLICT (role_id, permission_id) DO NOTHING;
