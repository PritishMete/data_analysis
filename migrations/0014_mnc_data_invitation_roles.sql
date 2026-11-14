-- MNC/data organization invitation roles.
-- Manager remains an authorization role; specialist roles use employee-level
-- dataset/analysis permissions and are differentiated by job function.
INSERT INTO roles(role_id, name) VALUES
    ('data_analyst', 'Data Analyst'),
    ('senior_data_analyst', 'Senior Data Analyst'),
    ('business_analyst', 'Business Analyst'),
    ('data_scientist', 'Data Scientist'),
    ('data_engineer', 'Data Engineer'),
    ('ml_engineer', 'ML Engineer'),
    ('analytics_engineer', 'Analytics Engineer'),
    ('bi_developer', 'BI Developer'),
    ('data_architect', 'Data Architect'),
    ('data_quality_analyst', 'Data Quality Analyst'),
    ('data_governance_analyst', 'Data Governance Analyst')
ON CONFLICT (role_id) DO NOTHING;

-- Manager permissions already exist in the seeded RBAC model. Specialist
-- roles intentionally receive the same baseline employee permissions; their
-- job-function identity does not silently grant administrative access.
INSERT INTO role_permissions(role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM roles r
CROSS JOIN permissions p
WHERE r.role_id IN (
    'data_analyst', 'senior_data_analyst', 'business_analyst',
    'data_scientist', 'data_engineer', 'ml_engineer',
    'analytics_engineer', 'bi_developer', 'data_architect',
    'data_quality_analyst', 'data_governance_analyst'
)
AND p.permission_id IN (
    'data.view','analysis.run','worksheet.create','pivot.create',
    'worksheet.modify','operation.undo.own','history.view',
    'organization.view','dataset.view_original',
    'dataset.create_working_copy','dataset.edit_working_copy',
    'working_copy.view','working_copy.modify','excel.mutate.working_copy'
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

ALTER TABLE roles ADD COLUMN IF NOT EXISTS system BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE roles
SET system=TRUE
WHERE role_id IN (
    'data_analyst','senior_data_analyst','business_analyst',
    'data_scientist','data_engineer','ml_engineer',
    'analytics_engineer','bi_developer','data_architect',
    'data_quality_analyst','data_governance_analyst'
);
