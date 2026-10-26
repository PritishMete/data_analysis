-- Managers may have the dataset.upload capability only as a prerequisite for
-- grant-gated uploads. Runtime authorization still requires an active,
-- unrevoked manager_dataset_upload_grants row for the exact branch.
INSERT INTO role_permissions (role_id, permission_id)
SELECT 'manager', 'dataset.upload'
WHERE EXISTS (
    SELECT 1 FROM roles WHERE role_id = 'manager'
)
ON CONFLICT (role_id, permission_id) DO NOTHING;
