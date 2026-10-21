-- Enforce one active branch per person across all assignment write paths.
-- Multiple role/section assignments within the same branch remain valid.
-- Organization-wide owner assignments are intentionally exempt.
CREATE OR REPLACE FUNCTION enforce_single_active_branch_assignment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'active'
       AND NEW.location_id IS NOT NULL
       AND NEW.role_id <> 'organization_owner' THEN
        -- Serialize concurrent assignment attempts for the same member.
        PERFORM 1
        FROM organization_members
        WHERE organization_id = NEW.organization_id
          AND principal_id = NEW.principal_id
        FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM organizational_assignments existing
            WHERE existing.organization_id = NEW.organization_id
              AND existing.principal_id = NEW.principal_id
              AND existing.status = 'active'
              AND existing.location_id IS NOT NULL
              AND existing.location_id <> NEW.location_id
              AND existing.role_id <> 'organization_owner'
              AND existing.assignment_id IS DISTINCT FROM NEW.assignment_id
        ) THEN
            RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'A person can have active assignments in only one branch.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS organizational_assignments_single_active_branch
    ON organizational_assignments;

CREATE TRIGGER organizational_assignments_single_active_branch
BEFORE INSERT OR UPDATE OF organization_id, principal_id, location_id, role_id, status
ON organizational_assignments
FOR EACH ROW
EXECUTE FUNCTION enforce_single_active_branch_assignment();
