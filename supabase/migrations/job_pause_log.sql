-- Pause and resume times for a production run.
-- Older jobs keep only jobs.total_paused_secs; this log starts from new pauses.

CREATE TABLE IF NOT EXISTS public.job_pause_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id text NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  paused_at timestamptz NOT NULL,
  resumed_at timestamptz
);

CREATE INDEX IF NOT EXISTS job_pause_log_job_idx
  ON public.job_pause_log (job_id, paused_at);

ALTER TABLE public.job_pause_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_select_job_pause_log ON public.job_pause_log;
DROP POLICY IF EXISTS staff_insert_job_pause_log ON public.job_pause_log;
DROP POLICY IF EXISTS staff_update_job_pause_log ON public.job_pause_log;

CREATE POLICY staff_select_job_pause_log ON public.job_pause_log
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY staff_insert_job_pause_log ON public.job_pause_log
  FOR INSERT TO authenticated WITH CHECK (public.is_staff());
CREATE POLICY staff_update_job_pause_log ON public.job_pause_log
  FOR UPDATE TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

GRANT SELECT, INSERT, UPDATE ON public.job_pause_log TO authenticated;
