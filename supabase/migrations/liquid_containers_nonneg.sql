-- Negative-balance guard on liquid stock.
-- A container can never legitimately hold negative litres or LPA. These CHECK
-- constraints are a DB-level backstop: if any code path (or manual edit) ever
-- tries to drive a balance below zero, the write fails loudly instead of
-- silently corrupting stock. The app already clamps with Math.max(0, …) on the
-- deduction/transfer paths and surfaces per-row failures, so this only catches
-- genuine bugs / bad manual input.
--
-- Verified safe before writing: 616 containers, 0 negative litres, 0 negative
-- LPA (min 0.00 each). NULLs pass the CHECK, matching the nullable columns.
--
-- ROLLBACK:
--   ALTER TABLE public.liquid_containers DROP CONSTRAINT IF EXISTS liquid_containers_current_litres_nonneg;
--   ALTER TABLE public.liquid_containers DROP CONSTRAINT IF EXISTS liquid_containers_current_lpa_nonneg;
--
-- Safe to re-run.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'liquid_containers_current_litres_nonneg'
       AND conrelid = 'public.liquid_containers'::regclass
  ) THEN
    ALTER TABLE public.liquid_containers
      ADD CONSTRAINT liquid_containers_current_litres_nonneg CHECK (current_litres >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'liquid_containers_current_lpa_nonneg'
       AND conrelid = 'public.liquid_containers'::regclass
  ) THEN
    ALTER TABLE public.liquid_containers
      ADD CONSTRAINT liquid_containers_current_lpa_nonneg CHECK (current_lpa >= 0);
  END IF;
END
$$;
