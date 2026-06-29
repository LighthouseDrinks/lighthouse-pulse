-- ============================================================
-- Client submission tables — restrict over-broad client policy
-- (audit finding: client could PATCH/DELETE own submissions freely).
--
-- cjs_client_own (client_job_submissions) and cbs_client_own
-- (client_bom_submissions) were FOR ALL with the tenant check
--   client_id = current_app_user_client_id()
-- on both USING and WITH CHECK. This is correctly tenant-scoped (no
-- cross-tenant leak), but within their own tenant a client could:
--   * UPDATE any column, e.g. flip status -> 'approved' (spoofing the
--     staff review queue — real approval is staff-only and creates the
--     job application-side), or
--   * DELETE their own submissions.
--
-- The portal only ever:
--   * INSERTs a new submission (status 'submitted'),
--   * UPDATEs status -> 'superseded' on resubmit (submitPortalJob /
--     submitPortalBom), or 'dismissed' on dismiss
--     (_dismissPortalJobSubmission / _dismissPortalBomSubmission).
--   It never DELETEs, and never changes other columns.
--
-- Fix: replace the FOR ALL policy with explicit SELECT + INSERT +
-- narrow UPDATE (status limited to 'superseded'/'dismissed'); no client
-- DELETE. Tenant scope unchanged. Staff policies (cjs_staff_all /
-- cbs_staff_all) are untouched.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── client_job_submissions ──────────────────────────────────
ALTER TABLE public.client_job_submissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cjs_client_own    ON public.client_job_submissions;
DROP POLICY IF EXISTS cjs_client_select ON public.client_job_submissions;
DROP POLICY IF EXISTS cjs_client_insert ON public.client_job_submissions;
DROP POLICY IF EXISTS cjs_client_update ON public.client_job_submissions;

CREATE POLICY cjs_client_select ON public.client_job_submissions
  FOR SELECT TO authenticated
  USING (client_id = public.current_app_user_client_id());

CREATE POLICY cjs_client_insert ON public.client_job_submissions
  FOR INSERT TO authenticated
  WITH CHECK (client_id = public.current_app_user_client_id());

CREATE POLICY cjs_client_update ON public.client_job_submissions
  FOR UPDATE TO authenticated
  USING (client_id = public.current_app_user_client_id())
  WITH CHECK (
    client_id = public.current_app_user_client_id()
    AND status IN ('superseded', 'dismissed')
  );

-- ── client_bom_submissions ──────────────────────────────────
ALTER TABLE public.client_bom_submissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cbs_client_own    ON public.client_bom_submissions;
DROP POLICY IF EXISTS cbs_client_select ON public.client_bom_submissions;
DROP POLICY IF EXISTS cbs_client_insert ON public.client_bom_submissions;
DROP POLICY IF EXISTS cbs_client_update ON public.client_bom_submissions;

CREATE POLICY cbs_client_select ON public.client_bom_submissions
  FOR SELECT TO authenticated
  USING (client_id = public.current_app_user_client_id());

CREATE POLICY cbs_client_insert ON public.client_bom_submissions
  FOR INSERT TO authenticated
  WITH CHECK (client_id = public.current_app_user_client_id());

CREATE POLICY cbs_client_update ON public.client_bom_submissions
  FOR UPDATE TO authenticated
  USING (client_id = public.current_app_user_client_id())
  WITH CHECK (
    client_id = public.current_app_user_client_id()
    AND status IN ('superseded', 'dismissed')
  );
