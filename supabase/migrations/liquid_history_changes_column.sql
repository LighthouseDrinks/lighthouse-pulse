-- ============================================================
-- liquid_history.changes: structured field-level diff for
-- manual container edits.
--
-- Manual Edit Container saves write a single `container_adjusted`
-- row that only snapshots litres/LPA/ABV before/after plus a fixed
-- note. Edits to location, owner/client, product, fill date,
-- capacity, CBW rotation, price, supplier, or notes left no trace.
--
-- This migration adds a JSONB `changes` column holding an array of
-- { field, label, before, after } objects so the UI can show exactly
-- what changed on each edit. The column is nullable and additive, so
-- existing rows and inserts that omit it keep working.
--
-- Safe to re-run: ADD COLUMN IF NOT EXISTS is idempotent.
-- ============================================================

ALTER TABLE public.liquid_history
  ADD COLUMN IF NOT EXISTS changes jsonb;
