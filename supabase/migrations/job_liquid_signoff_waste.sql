-- Persist bottling waste on the liquid sign-off.
-- Waste litres/reason were previously only embedded in the bottling_deduction
-- history note (free text). These additive columns make waste a queryable,
-- reportable figure alongside water_added / leftover_* / final_litres.
-- Additive + idempotent: safe to re-run; no effect on existing rows.

ALTER TABLE public.job_liquid_signoff
  ADD COLUMN IF NOT EXISTS waste_litres numeric;

ALTER TABLE public.job_liquid_signoff
  ADD COLUMN IF NOT EXISTS waste_reason text;
