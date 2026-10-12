-- Grant Manager the scoped users.manage capability used by management
-- section/team operations. Runtime domain checks still bind every mutation to
-- the Manager's active branch assignment; this does not grant org-wide control.
INSERT INTO role_permissions(role_id, permission_id)
VALUES ('manager', 'users.manage')
ON CONFLICT (role_id, permission_id) DO NOTHING;
