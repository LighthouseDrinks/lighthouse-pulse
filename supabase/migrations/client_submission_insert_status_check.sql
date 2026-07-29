-- ============================================================
-- Client submissions — pin INSERT status to 'submitted'
-- (audit follow-up to client_submission_rls_tighten.sql).
--
-- client_submission_rls_tighten.sql already limits client UPDATEs to
-- status IN ('superseded','dismissed'), but the client INSERT policies
-- (cjs_client_insert / cbs_client_insert) only checked tenant scope:
--     WITH CHECK (client_id = current_app_user_client_id())
-- so the API (not the portal UI) could create a row already
-- status = 'approved', spoofing the staff review queue.
--
-- Fix: require the initial status to be 'submitted' on client INSERT.
-- The portal always inserts status:'submitted' (submitPortalJob /
-- submitPortalBom), so this is non-breaking. Staff INSERT policies
-- (cjs_staff_all / cbs_staff_all) are untouched.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── client_job_submissions ──────────────────────────────────
DROP POLICY IF EXISTS cjs_client_insert ON public.client_job_submissions;
CREATE POLICY cjs_client_insert ON public.client_job_submissions
  FOR INSERT TO authenticated
  WITH CHECK (
    client_id = public.current_app_user_client_id()
    AND status = 'submitted'
  );

-- ── client_bom_submissions ──────────────────────────────────
DROP POLICY IF EXISTS cbs_client_insert ON public.client_bom_submissions;
CREATE POLICY cbs_client_insert ON public.client_bom_submissions
  FOR INSERT TO authenticated
  WITH CHECK (
    client_id = public.current_app_user_client_id()
    AND status = 'submitted'
  );
