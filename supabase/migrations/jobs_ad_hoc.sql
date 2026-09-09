-- Ad hoc jobs: isolated working log + born-complete billing stub on jobs.
-- Existing production jobs are unchanged (is_ad_hoc defaults false).

ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS is_ad_hoc boolean NOT NULL DEFAULT false;
ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS ad_hoc_charge numeric;

COMMENT ON COLUMN public.jobs.is_ad_hoc IS
  'True only for stubs created when an ad_hoc_jobs row is completed. Never used for production jobs.';
COMMENT ON COLUMN public.jobs.ad_hoc_charge IS
  'Optional charge copied from ad_hoc_jobs.charge for Finance invoice prefill.';

CREATE TABLE IF NOT EXISTS public.ad_hoc_jobs (
  id text PRIMARY KEY,
  client_id text REFERENCES public.clients(id),
  name text NOT NULL,
  description text NOT NULL,
  po_number text,
  charge numeric,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'complete', 'cancelled')),
  completed_job_id text REFERENCES public.jobs(id),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS ad_hoc_jobs_status_idx ON public.ad_hoc_jobs (status);
CREATE INDEX IF NOT EXISTS ad_hoc_jobs_client_idx ON public.ad_hoc_jobs (client_id);

ALTER TABLE public.ad_hoc_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_select_ad_hoc_jobs ON public.ad_hoc_jobs;
DROP POLICY IF EXISTS staff_insert_ad_hoc_jobs ON public.ad_hoc_jobs;
DROP POLICY IF EXISTS staff_update_ad_hoc_jobs ON public.ad_hoc_jobs;

CREATE POLICY staff_select_ad_hoc_jobs ON public.ad_hoc_jobs
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY staff_insert_ad_hoc_jobs ON public.ad_hoc_jobs
  FOR INSERT TO authenticated WITH CHECK (public.is_staff());
CREATE POLICY staff_update_ad_hoc_jobs ON public.ad_hoc_jobs
  FOR UPDATE TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

GRANT SELECT, INSERT, UPDATE ON public.ad_hoc_jobs TO authenticated;

-- Hide ad hoc stubs from the client portal (same columns as live view).
CREATE OR REPLACE VIEW public.v_portal_jobs
  WITH (security_invoker = false)
AS
SELECT
  j.id,
  j.bom_id,
  j.product_name,
  j.stage,
  j.job_target_type,
  j.bottle_target,
  j.liquid_litres,
  j.scheduled_start,
  j.scheduled_date,
  j.job_ready_date,
  j.created_at,
  j.actual_bottles_produced,
  j.date_completed,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.notes
    ELSE NULL
  END AS notes,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.po_number
    WHEN EXISTS (
      SELECT 1 FROM public.client_job_submissions s
      WHERE s.approved_job_id = j.id
        AND s.client_id = public.current_app_user_client_id()
    ) THEN j.po_number
    ELSE NULL
  END AS po_number,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.po_attachments
    WHEN EXISTS (
      SELECT 1 FROM public.client_job_submissions s
      WHERE s.approved_job_id = j.id
        AND s.client_id = public.current_app_user_client_id()
    ) THEN j.po_attachments
    ELSE NULL
  END AS po_attachments,
  (j.client_id = 'CLI-000'
    AND j.client_id IS DISTINCT FROM public.current_app_user_client_id())
    AS is_lighthouse_produced
FROM public.jobs j
WHERE public.is_client_user()
  AND (j.is_ad_hoc IS NOT TRUE)
  AND (
    j.client_id = public.current_app_user_client_id()
    OR (
      j.client_id = 'CLI-000'
      AND j.bom_id IN (SELECT s.id FROM public.portal_shared_lighthouse_bom_ids() s)
    )
  );

GRANT SELECT ON public.v_portal_jobs TO authenticated;

NOTIFY pgrst, 'reload schema';
