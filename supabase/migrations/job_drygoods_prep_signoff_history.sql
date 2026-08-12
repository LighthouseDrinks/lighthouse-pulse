-- ============================================================
-- job_drygoods_prep.signoff_history: audit trail for Supply
-- Chain sign-off / reopen cycles.
--
-- The dry-goods Supply Chain sign-off (signed_by_coordinator /
-- signed_at_coordinator) previously had no way to be reopened
-- and no record of past sign-offs. This adds a JSONB array of
-- { action: 'signed' | 'reopened', by, at, reason,
--   previously_signed_by } entries, mirroring
-- job_liquid_signoff.signoff_history used by the Liquid
-- sign-off Reopen feature.
--
-- Safe to re-run: ADD COLUMN IF NOT EXISTS is idempotent.
-- ============================================================

ALTER TABLE public.job_drygoods_prep
  ADD COLUMN IF NOT EXISTS signoff_history jsonb NOT NULL DEFAULT '[]'::jsonb;
