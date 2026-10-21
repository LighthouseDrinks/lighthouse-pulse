-- Fill-weight spot checks under Weights & Measures.
-- job_wm_fill_refs holds an optional saved reference full weight (g).
-- Until a row exists, the app uses the first sample batch's average full weight.
-- Each check snapshots the reference and the gram tolerance so a later edit
-- does not rewrite history. Tolerance itself is not stored here: the app
-- derives it as T1 (mL) × average SG of that first batch.

CREATE TABLE IF NOT EXISTS public.job_wm_fill_refs (
  job_id text PRIMARY KEY REFERENCES public.jobs(id) ON DELETE CASCADE,
  target_full_g numeric NOT NULL CHECK (target_full_g > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);

CREATE TABLE IF NOT EXISTS public.job_wm_fill_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id text NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  weighed_g numeric NOT NULL CHECK (weighed_g > 0),
  target_full_g numeric NOT NULL CHECK (target_full_g > 0),
  tolerance_g numeric NOT NULL CHECK (tolerance_g >= 0),
  passed boolean NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT now(),
  checked_by text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS job_wm_fill_checks_job_idx
  ON public.job_wm_fill_checks (job_id, checked_at DESC);

ALTER TABLE public.job_wm_fill_refs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_wm_fill_checks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_all ON public.job_wm_fill_refs;
CREATE POLICY staff_all ON public.job_wm_fill_refs
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

DROP POLICY IF EXISTS staff_all ON public.job_wm_fill_checks;
CREATE POLICY staff_all ON public.job_wm_fill_checks
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.job_wm_fill_refs TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.job_wm_fill_checks TO authenticated;
