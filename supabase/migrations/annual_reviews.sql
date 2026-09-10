-- ============================================================
-- annual_reviews — one written review per person per calendar year
--
-- Write access matches probation (is_probation_admin / HR admins).
-- Completed rows are readable by the employee, their line manager,
-- and HR admins. Meeting dates also live on hr_profiles.next_review_date
-- so line managers can still schedule from Management without this table.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.annual_reviews (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  review_year     int NOT NULL,
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
  CONSTRAINT annual_reviews_year_check CHECK (review_year >= 2000 AND review_year <= 2100),
  CONSTRAINT annual_reviews_status_check CHECK (status IN ('draft', 'completed')),
  CONSTRAINT annual_reviews_user_year_key UNIQUE (user_id, review_year)
);

CREATE INDEX IF NOT EXISTS annual_reviews_user_id_idx
  ON public.annual_reviews (user_id);
CREATE INDEX IF NOT EXISTS annual_reviews_status_idx
  ON public.annual_reviews (status);

ALTER TABLE public.annual_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS annual_reviews_admin_all ON public.annual_reviews;
DROP POLICY IF EXISTS annual_reviews_completed_select ON public.annual_reviews;

CREATE POLICY annual_reviews_admin_all ON public.annual_reviews
  FOR ALL TO authenticated
  USING      (public.is_probation_admin())
  WITH CHECK (public.is_probation_admin());

CREATE POLICY annual_reviews_completed_select ON public.annual_reviews
  FOR SELECT TO authenticated
  USING (
    status = 'completed'
    AND (
      user_id = public.current_app_user_id()
      OR public.is_hr_admin()
      OR EXISTS (
        SELECT 1
        FROM public.hr_profiles hp
        WHERE hp.user_id = annual_reviews.user_id
          AND hp.reports_to = public.current_app_user_id()
      )
    )
  );

REVOKE ALL ON public.annual_reviews FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.annual_reviews TO authenticated;
