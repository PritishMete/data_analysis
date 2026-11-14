-- Backfill legacy accepted invitations into branch assignments only when
-- the inviter has exactly one active branch and the accepted principal has
-- no existing active assignment. Never guess across multiple branches.

WITH candidates AS (
    SELECT
        i.invitation_id,
        i.organization_id,
        i.accepted_by_principal_id,
        min(oa.location_id) AS location_id,
        count(DISTINCT oa.location_id) AS inviter_location_count
    FROM invitations i
    JOIN organizational_assignments oa
      ON oa.organization_id = i.organization_id
     AND oa.principal_id = i.created_by_principal_id
     AND oa.status = 'active'
     AND oa.location_id IS NOT NULL
    WHERE i.status = 'accepted'
      AND i.location_id IS NULL
      AND i.accepted_by_principal_id IS NOT NULL
    GROUP BY
        i.invitation_id,
        i.organization_id,
        i.accepted_by_principal_id
    HAVING count(DISTINCT oa.location_id) = 1
),
unique_principals AS (
    SELECT
        c.*,
        count(*) OVER (
            PARTITION BY c.organization_id, c.accepted_by_principal_id
        ) AS accepted_invitation_count
    FROM candidates c
)
UPDATE invitations i
SET location_id = u.location_id
FROM unique_principals u
WHERE i.invitation_id = u.invitation_id
  AND u.accepted_invitation_count = 1;

INSERT INTO organizational_assignments
    (assignment_id, organization_id, principal_id, location_id, role_id, status)
SELECT
    'asg_' || md5(i.invitation_id || ':legacy-branch-backfill'),
    i.organization_id,
    i.accepted_by_principal_id,
    i.location_id,
    i.role_id,
    'active'
FROM invitations i
WHERE i.status = 'accepted'
  AND i.location_id IS NOT NULL
  AND i.accepted_by_principal_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM organizational_assignments oa
      WHERE oa.organization_id = i.organization_id
        AND oa.principal_id = i.accepted_by_principal_id
        AND oa.status = 'active'
  )
  AND NOT EXISTS (
      SELECT 1
      FROM organizational_assignments oa
      WHERE oa.assignment_id = 'asg_' || md5(i.invitation_id || ':legacy-branch-backfill')
  );
