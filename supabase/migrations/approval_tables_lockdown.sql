-- ============================================================
-- Magic-link approval tables — tighten authenticated access (Phase 1,
-- finding C-6, partial).
--
-- job_bom_approvals and job_label_approvals power the PUBLIC magic-link
-- pages (#/bom-approval/<token>, label approval), which run as the anon
-- role. They carried:
--   * authenticated ALL = true  -> any logged-in client could list /
--     modify EVERY approval row.
--   * anon UPDATE/SELECT = true -> any anonymous caller can PATCH any
--     row, not just the token holder.
--
-- This migration removes the authenticated wide-open access (replacing it
-- with staff-only), which stops a logged-in portal client from touching
-- approvals. The ANON token policies are intentionally LEFT in place so
-- the existing magic-link flow keeps working; properly token-scoping the
-- anon UPDATE (so a caller can only update the row whose token they hold)
-- is tracked as a Phase 2 task because it requires the magic-link client
-- to carry the token in the request and a matching policy predicate.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── job_bom_approvals ───────────────────────────────────────
ALTER TABLE public.job_bom_approvals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS job_bom_approvals_auth_all ON public.job_bom_approvals;
DROP POLICY IF EXISTS staff_all                  ON public.job_bom_approvals;
CREATE POLICY staff_all ON public.job_bom_approvals
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
-- Kept (magic-link, Phase 2 token-scoping):
--   job_bom_approvals_anon_select, job_bom_approvals_anon_update

-- ── job_label_approvals ─────────────────────────────────────
ALTER TABLE public.job_label_approvals ENABLE ROW LEVEL SECURITY;
-- Existing staff_all here was authenticated ALL = true (not is_staff()).
DROP POLICY IF EXISTS staff_all ON public.job_label_approvals;
CREATE POLICY staff_all ON public.job_label_approvals
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
-- Kept (magic-link, Phase 2 token-scoping):
--   anon_token_read, anon_token_update
