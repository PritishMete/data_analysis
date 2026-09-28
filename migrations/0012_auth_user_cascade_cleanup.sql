-- Supabase Auth account deletion cleanup.
-- This migration replaces the earlier auth.users delete trigger with a
-- complete, transaction-safe cleanup of the deleted principal's authorization
-- data. Shared organizations are preserved; an organization is deleted only
-- when it has no remaining members.

CREATE OR REPLACE FUNCTION public.insightflow_cleanup_deleted_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    principal TEXT;
    org RECORD;
    replacement_principal TEXT;
BEGIN
    SELECT ib.principal_id
      INTO principal
      FROM public.identity_bindings ib
     WHERE ib.provider = 'supabase'
       AND ib.provider_subject = OLD.id::text
     LIMIT 1;

    IF principal IS NULL THEN
        SELECT ib.principal_id
          INTO principal
          FROM public.identity_bindings ib
         WHERE ib.provider = 'firebase'
           AND ib.firebase_uid = OLD.id::text
         LIMIT 1;
    END IF;

    -- No application identity is linked to this Auth user.
    IF principal IS NULL THEN
        RETURN OLD;
    END IF;

    -- Capture organizations before membership deletion.
    FOR org IN
        SELECT DISTINCT om.organization_id
        FROM public.organization_members om
        WHERE om.principal_id = principal
    LOOP
        -- Remove principal-scoped authorization first.
        DELETE FROM public.member_roles
         WHERE principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.resource_grants
         WHERE principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.working_copy_authorization
         WHERE created_by_principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.dataset_authorization
         WHERE owner_principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.authorization_resources
         WHERE owner_principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.delegations
         WHERE team_lead_principal_id = principal
           AND organization_id = org.organization_id;

        UPDATE public.audit_events
           SET actor_principal_id = NULL
         WHERE actor_principal_id = principal
           AND organization_id = org.organization_id;

        UPDATE public.invitations
           SET created_by_principal_id = NULL
         WHERE created_by_principal_id = principal
           AND organization_id = org.organization_id;

        UPDATE public.invitations
           SET accepted_by_principal_id = NULL
         WHERE accepted_by_principal_id = principal
           AND organization_id = org.organization_id;

        UPDATE public.approved_employees
           SET principal_id = NULL
         WHERE principal_id = principal
           AND organization_id = org.organization_id;

        UPDATE public.approved_employees
           SET approved_by_principal_id = NULL
         WHERE approved_by_principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.organizational_assignments
         WHERE principal_id = principal
           AND organization_id = org.organization_id;

        DELETE FROM public.organization_members
         WHERE principal_id = principal
           AND organization_id = org.organization_id;

        -- organizations.created_by_principal_id is intentionally NOT NULL.
        -- If other members remain, transfer ownership to one of them.
        SELECT om.principal_id
          INTO replacement_principal
          FROM public.organization_members om
         WHERE om.organization_id = org.organization_id
           AND om.status <> 'removed'
         ORDER BY om.created_at
         LIMIT 1;

        IF replacement_principal IS NOT NULL THEN
            UPDATE public.organizations
               SET created_by_principal_id = replacement_principal
             WHERE organization_id = org.organization_id
               AND created_by_principal_id = principal;
        ELSE
            -- No remaining members means this organization belongs exclusively
            -- to the deleted account. CASCADE removes its dependent data.
            DELETE FROM public.organizations
             WHERE organization_id = org.organization_id;
        END IF;
    END LOOP;

    -- Remove any principal-scoped records outside memberships.
    DELETE FROM public.member_roles
     WHERE principal_id = principal;

    DELETE FROM public.resource_grants
     WHERE principal_id = principal;

    DELETE FROM public.working_copy_authorization
     WHERE created_by_principal_id = principal;

    DELETE FROM public.dataset_authorization
     WHERE owner_principal_id = principal;

    DELETE FROM public.authorization_resources
     WHERE owner_principal_id = principal;

    DELETE FROM public.delegations
     WHERE team_lead_principal_id = principal;

    UPDATE public.audit_events
       SET actor_principal_id = NULL
     WHERE actor_principal_id = principal;

    UPDATE public.invitations
       SET created_by_principal_id = NULL
     WHERE created_by_principal_id = principal;

    UPDATE public.invitations
       SET accepted_by_principal_id = NULL
     WHERE accepted_by_principal_id = principal;

    UPDATE public.approved_employees
       SET principal_id = NULL
     WHERE principal_id = principal;

    UPDATE public.approved_employees
       SET approved_by_principal_id = NULL
     WHERE approved_by_principal_id = principal;

    DELETE FROM public.organizational_assignments
     WHERE principal_id = principal;

    DELETE FROM public.identity_bindings
     WHERE principal_id = principal;

    DELETE FROM public.principals
     WHERE principal_id = principal;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS insightflow_cleanup_deleted_auth_user
    ON auth.users;

CREATE TRIGGER insightflow_cleanup_deleted_auth_user
AFTER DELETE ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.insightflow_cleanup_deleted_auth_user();

-- The Auth service invokes this trigger as supabase_auth_admin.
-- The function itself runs with its owner's privileges, while this grant
-- allows the trigger invocation to succeed.
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
REVOKE ALL ON FUNCTION public.insightflow_cleanup_deleted_auth_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.insightflow_cleanup_deleted_auth_user() TO supabase_auth_admin;
