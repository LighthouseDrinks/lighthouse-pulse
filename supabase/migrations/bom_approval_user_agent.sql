-- ============================================================
-- Add client_user_agent to job_bom_approvals
-- The magic-link page sends navigator.userAgent on submit;
-- this column was referenced in the PATCH but never created.
-- ============================================================
ALTER TABLE job_bom_approvals
  ADD COLUMN IF NOT EXISTS client_user_agent TEXT;
