-- Managers may submit proposed changes for review but must not receive the
-- direct upload capability used by official dataset ingestion.
-- This changes authorization metadata only; it does not modify dataset records.
DELETE FROM role_permissions
WHERE role_id = 'manager'
  AND permission_id = 'dataset.upload';
