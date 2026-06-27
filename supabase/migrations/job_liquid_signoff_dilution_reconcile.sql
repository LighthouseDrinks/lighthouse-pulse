-- ============================================================
-- job_liquid_signoff: columns for cask-strength linking and
-- close-out dilution reconciliation.
--
-- Lets a job link liquid containers at any strength (cask /
-- higher than bottling) and reconcile the dilution at job
-- completion instead of forcing a pre-dilute round-trip:
--   dilution_scope        'requirement' | 'all' (Work Order scope)
--   water_added           actual RO water added at close (litres)
--   leftover_strength     'original' | 'bottling' (state of any leftover)
--   leftover_container_id where the leftover physically ended up
--   leftover_cbw          OPTIONAL CBW rotation for the leftover vessel
--
-- All columns are nullable and additive. CBW is intentionally
-- optional and must never be required to save.
--
-- Safe to re-run: each ADD COLUMN uses IF NOT EXISTS, so the
-- migration is idempotent and performs no data changes on
-- existing rows (they default to NULL).
-- ============================================================

ALTER TABLE public.job_liquid_signoff
  ADD COLUMN IF NOT EXISTS dilution_scope        text,
  ADD COLUMN IF NOT EXISTS water_added           numeric,
  ADD COLUMN IF NOT EXISTS leftover_strength     text,
  ADD COLUMN IF NOT EXISTS leftover_container_id text,
  ADD COLUMN IF NOT EXISTS leftover_cbw          text;

-- Guard the small enum-like columns without blocking existing
-- rows (NOT VALID skips the recheck of pre-existing NULLs).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
      JOIN pg_class t      ON t.oid = c.conrelid
      JOIN pg_namespace n  ON n.oid = t.relnamespace
     WHERE n.nspname = 'public'
       AND t.relname = 'job_liquid_signoff'
       AND c.conname = 'job_liquid_signoff_dilution_scope_check'
  ) THEN
    ALTER TABLE public.job_liquid_signoff
      ADD CONSTRAINT job_liquid_signoff_dilution_scope_check
      CHECK (dilution_scope IS NULL OR dilution_scope IN ('requirement','all'))
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
      JOIN pg_class t      ON t.oid = c.conrelid
      JOIN pg_namespace n  ON n.oid = t.relnamespace
     WHERE n.nspname = 'public'
       AND t.relname = 'job_liquid_signoff'
       AND c.conname = 'job_liquid_signoff_leftover_strength_check'
  ) THEN
    ALTER TABLE public.job_liquid_signoff
      ADD CONSTRAINT job_liquid_signoff_leftover_strength_check
      CHECK (leftover_strength IS NULL OR leftover_strength IN ('original','bottling'))
      NOT VALID;
  END IF;
END
$$;
