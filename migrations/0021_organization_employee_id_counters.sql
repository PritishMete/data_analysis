-- Server-owned monotonic Employee ID allocator, scoped to each organization.
-- Preserve existing member IDs and seed above each organization's highest EMP suffix.
CREATE TABLE IF NOT EXISTS public.organization_employee_id_counters (
    organization_id TEXT PRIMARY KEY
        REFERENCES public.organizations(organization_id) ON DELETE CASCADE,
    last_issued BIGINT NOT NULL DEFAULT 0 CHECK (last_issued >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.organization_employee_id_counters
    (organization_id, last_issued)
SELECT o.organization_id,
       COALESCE(
           MAX(substring(upper(m.employee_id) FROM '^EMP([0-9]+)$')::BIGINT),
           0
       )
FROM public.organizations o
LEFT JOIN public.organization_members m
  ON m.organization_id = o.organization_id
GROUP BY o.organization_id
ON CONFLICT (organization_id) DO UPDATE
SET last_issued = GREATEST(
        organization_employee_id_counters.last_issued,
        EXCLUDED.last_issued
    ),
    updated_at = now();

-- Existing invitations retain any historical value; new invitations do not
-- reserve an ID. The actual membership acceptance allocates it transactionally.
ALTER TABLE public.invitations
    ALTER COLUMN employee_id DROP NOT NULL;

ALTER TABLE public.organization_employee_id_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.organization_employee_id_counters
    FROM PUBLIC, anon, authenticated;
