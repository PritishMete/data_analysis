-- Preflight the one-active-branch rule against existing data.
--
-- Do not automatically deactivate or move assignments here: the database
-- cannot know which branch is the intended assignment for a person. Guessing
-- could silently remove access or grant access to the wrong branch.
--
-- If conflicts exist, this migration intentionally fails before recording
-- itself as applied. The DETAIL lists each affected organization/member,
-- branch IDs, and assignment IDs. An organization owner/operator must review
-- the listed assignments and deactivate or correct the obsolete assignment(s),
-- then rerun the migration runner.
DO $$
DECLARE
    conflict_report TEXT;
BEGIN
    SELECT string_agg(
        format(
            'organization_id=%s; principal_id=%s; location_ids=%s; assignment_ids=%s',
            conflicts.organization_id,
            conflicts.principal_id,
            conflicts.location_ids,
            conflicts.assignment_ids
        ),
        E'\n'
        ORDER BY conflicts.organization_id, conflicts.principal_id
    )
    INTO conflict_report
    FROM (
        SELECT
            organization_id,
            principal_id,
            array_agg(DISTINCT location_id::TEXT ORDER BY location_id::TEXT) AS location_ids,
            array_agg(assignment_id::TEXT ORDER BY assignment_id::TEXT) AS assignment_ids
        FROM organizational_assignments
        WHERE status = 'active'
          AND location_id IS NOT NULL
          AND role_id <> 'organization_owner'
        GROUP BY organization_id, principal_id
        HAVING count(DISTINCT location_id) > 1
    ) AS conflicts;

    IF conflict_report IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = 'Existing cross-branch assignment conflicts must be reviewed before the branch restriction can be considered ready.',
            DETAIL = conflict_report,
            HINT = 'For each listed principal, confirm the intended branch with the organization owner, deactivate or correct only the obsolete assignment(s), then rerun the authorization migration runner. Do not choose a branch automatically.';
    END IF;
END;
$$;
