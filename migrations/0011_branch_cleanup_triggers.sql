-- Branch cleanup lifecycle.
-- Keep application authorization data synchronized with Supabase Auth and with
-- direct deletion of organizational locations.

CREATE OR REPLACE FUNCTION public.insightflow_cleanup_orphaned_branch_organization()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Ignore location deletes caused by a parent organization delete. The
    -- direct-delete path is responsible for deciding whether the organization
    -- has become orphaned.
    IF pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;

    DELETE FROM public.organizations
    WHERE organization_id = OLD.organization_id
      AND NOT EXISTS (
          SELECT 1
          FROM public.locations
          WHERE organization_id = OLD.organization_id
      );

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS insightflow_cleanup_orphaned_branch_organization
    ON public.locations;

CREATE TRIGGER insightflow_cleanup_orphaned_branch_organization
AFTER DELETE ON public.locations
FOR EACH ROW
EXECUTE FUNCTION public.insightflow_cleanup_orphaned_branch_organization();


CREATE OR REPLACE FUNCTION public.insightflow_cleanup_deleted_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    branch RECORD;
    principal TEXT;
BEGIN
    -- Supabase Auth users use the auth.users UUID as the subject stored by
    -- the Supabase authorization provider. Keep the legacy Firebase UID path
    -- as well so the same cleanup is safe during provider migration.
    FOR principal IN
        SELECT DISTINCT ib.principal_id
        FROM public.identity_bindings ib
        WHERE (
            ib.provider = 'supabase'
            AND ib.provider_subject = OLD.id::text
        )
        OR (
            ib.provider = 'firebase'
            AND ib.firebase_uid = OLD.id::text
        )
    LOOP
        FOR branch IN
            SELECT DISTINCT oa.organization_id, oa.location_id
            FROM public.organizational_assignments oa
            JOIN public.member_roles mr
              ON mr.organization_id = oa.organization_id
             AND mr.principal_id = oa.principal_id
             AND mr.role_id = 'branch_head'
            WHERE oa.principal_id = principal
              AND oa.location_id IS NOT NULL
              AND oa.status = 'active'
        LOOP
            -- locations -> sections/assignments are ON DELETE CASCADE.
            -- The organization is removed below only when this was its last
            -- remaining branch.
            DELETE FROM public.locations
            WHERE location_id = branch.location_id
              AND organization_id = branch.organization_id;

            DELETE FROM public.organizations
            WHERE organization_id = branch.organization_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.locations
                  WHERE organization_id = branch.organization_id
              );
        END LOOP;

        DELETE FROM public.identity_bindings
        WHERE principal_id = principal
          AND (
              (provider = 'supabase' AND provider_subject = OLD.id::text)
              OR (provider = 'firebase' AND firebase_uid = OLD.id::text)
          );

        -- Do not remove a principal that still has another identity or
        -- membership. Otherwise remove the now-unreferenced authorization
        -- principal as part of account deletion.
        DELETE FROM public.principals
        WHERE principal_id = principal
          AND NOT EXISTS (
              SELECT 1 FROM public.identity_bindings
              WHERE principal_id = principal
          )
          AND NOT EXISTS (
              SELECT 1 FROM public.organization_members
              WHERE principal_id = principal
          )
          AND NOT EXISTS (
              SELECT 1 FROM public.organizational_assignments
              WHERE principal_id = principal
          );
    END LOOP;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS insightflow_cleanup_deleted_auth_user
    ON auth.users;

CREATE TRIGGER insightflow_cleanup_deleted_auth_user
AFTER DELETE ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.insightflow_cleanup_deleted_auth_user();

-- Auth trigger functions execute with elevated database privileges because
-- Supabase Auth performs the DELETE from its managed schema.
REVOKE ALL ON FUNCTION public.insightflow_cleanup_deleted_auth_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.insightflow_cleanup_deleted_auth_user() TO supabase_auth_admin;
