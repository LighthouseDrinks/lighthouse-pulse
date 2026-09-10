-- ============================================================
-- probation_reviews — 1 / 3 / 6 month probation reviews
--
-- Written only by Managing Director, Operations Director, and
-- Business Analyst (is_probation_admin). Completed rows are
-- readable by the employee, their line manager (reports_to),
-- and HR admins who can already open Employee Details.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_app_user_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT id FROM public.app_users WHERE auth_user_id = auth.uid() LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.is_probation_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT public.is_hr_admin()
      OR EXISTS (
        SELECT 1
        FROM public.app_users au
        WHERE au.auth_user_id = auth.uid()
          AND au.role IN ('managing_director', 'operations_director', 'business_analyst', 'human_resources')
      );
$function$;

REVOKE EXECUTE ON FUNCTION public.current_app_user_id() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.current_app_user_id() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_probation_admin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_probation_admin() TO authenticated;

CREATE TABLE IF NOT EXISTS public.probation_reviews (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  milestone       smallint NOT NULL,
  scheduled_date  date,
  answers         jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes           text,
  status          text NOT NULL DEFAULT 'draft',
  completed_at    timestamptz,
  completed_by    uuid,
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT probation_reviews_milestone_check CHECK (milestone IN (1, 3, 6)),
  CONSTRAINT probation_reviews_status_check CHECK (status IN ('draft', 'completed')),
  CONSTRAINT probation_reviews_user_milestone_key UNIQUE (user_id, milestone)
);

CREATE INDEX IF NOT EXISTS probation_reviews_user_id_idx
  ON public.probation_reviews (user_id);
CREATE INDEX IF NOT EXISTS probation_reviews_status_idx
  ON public.probation_reviews (status);

ALTER TABLE public.probation_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS probation_reviews_admin_all ON public.probation_reviews;
DROP POLICY IF EXISTS probation_reviews_completed_select ON public.probation_reviews;

CREATE POLICY probation_reviews_admin_all ON public.probation_reviews
  FOR ALL TO authenticated
  USING      (public.is_probation_admin())
  WITH CHECK (public.is_probation_admin());

CREATE POLICY probation_reviews_completed_select ON public.probation_reviews
  FOR SELECT TO authenticated
  USING (
    status = 'completed'
    AND (
      user_id = public.current_app_user_id()
      OR public.is_hr_admin()
      OR EXISTS (
        SELECT 1
        FROM public.hr_profiles hp
        WHERE hp.user_id = probation_reviews.user_id
          AND hp.reports_to = public.current_app_user_id()
      )
    )
  );

REVOKE ALL ON public.probation_reviews FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.probation_reviews TO authenticated;
