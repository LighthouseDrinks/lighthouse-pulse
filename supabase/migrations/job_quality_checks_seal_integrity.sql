-- On-line production checks: Seal integrity check (Pass / Fail).
-- Nullable so existing rounds stay valid and a blank dropdown is not stored.

ALTER TABLE public.job_quality_checks
  ADD COLUMN IF NOT EXISTS seal_integrity text;
