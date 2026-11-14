-- Enforce the managed-dataset workflow:
-- Branch Head and Manager may upload datasets.
-- Lower roles never receive upload authority. Dataset copy access is explicit
-- per-resource through dataset.create_working_copy grants.
INSERT INTO role_permissions(role_id, permission_id)
VALUES ('manager', 'dataset.upload')
ON CONFLICT (role_id, permission_id) DO NOTHING;
