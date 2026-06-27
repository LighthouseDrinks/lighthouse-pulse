-- ============================================================
-- bom_history: audit trail for BOM approval workflow.
--
-- Root cause of "No approval history" in the UI: the app writes one
-- immutable row per workflow action via _bomRecordHistory() (client
-- side, using the logged-in user's JWT). The pre-existing bom_history
-- table defined bom_id as uuid, but boms.id is a text code like
-- 'BOM-004-MPQRQSM5', so every insert failed type validation and the
-- error was swallowed. The approval still succeeded (revision bumped on
-- boms), so BOMs reached Rev 3 with a permanently blank history.
--
-- This migration:
--   1. Ensures the table + columns the app expects exist.
--   2. Enables RLS with permissive authenticated read/write,
--      mirroring the app-table convention used by
--      client_invoice_rates / job_invoice_lines (jobs_to_invoice.sql).
--   3. Backfills a single synthetic "approved" event for existing
--      approved BOMs so their history is not blank. Per-revision
--      timestamps were never recorded, so this is one approximate
--      event per BOM (dated at boms.revised_at), not the full chain.
--
-- bom_id is TEXT: the app passes boms.id as a JS string for both
-- inserts and the ?bom_id=eq.<id> read, so TEXT works whether boms.id
-- is a uuid or a human-readable code. The backfill casts boms.id to
-- text to compare against this column.
--
-- Safe to re-run: table/columns/index/policies are all guarded,
-- and the backfill only touches BOMs that have no history yet.
-- ============================================================

-- 1. Table + columns ------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bom_history (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bom_id          text NOT NULL,
  action          text NOT NULL,
  from_status     text,
  to_status       text,
  actor           text,
  revision_number integer,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Additive guards in case an older/partial table already exists.
ALTER TABLE public.bom_history
  ADD COLUMN IF NOT EXISTS bom_id          text,
  ADD COLUMN IF NOT EXISTS action          text,
  ADD COLUMN IF NOT EXISTS from_status     text,
  ADD COLUMN IF NOT EXISTS to_status       text,
  ADD COLUMN IF NOT EXISTS actor           text,
  ADD COLUMN IF NOT EXISTS revision_number integer,
  ADD COLUMN IF NOT EXISTS created_at      timestamptz NOT NULL DEFAULT now();

-- A pre-existing bom_history table defined bom_id as uuid, but boms.id
-- is a text code (e.g. 'BOM-004-MPQRQSM5'). That mismatch made every
-- history insert fail (silently swallowed), which is why history was
-- always empty. Coerce bom_id to text so it matches boms.id. The table
-- is empty so the cast is a no-op on data; if bom_id is already text
-- this statement is harmless.
ALTER TABLE public.bom_history
  ALTER COLUMN bom_id TYPE text USING bom_id::text;

-- Fast lookup for the UI query: ?bom_id=eq.<id>&order=created_at.desc
CREATE INDEX IF NOT EXISTS bom_history_bom_id_created_at_idx
  ON public.bom_history (bom_id, created_at DESC);

-- 2. RLS + policies -------------------------------------------------
ALTER TABLE public.bom_history ENABLE ROW LEVEL SECURITY;

-- Permissive read/write for any authenticated session (staff app and
-- authenticated client portal), matching the convention used by other
-- app CRUD tables. CREATE POLICY has no IF NOT EXISTS, so guard it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'bom_history'
       AND policyname = 'bom_history_auth_all'
  ) THEN
    CREATE POLICY "bom_history_auth_all" ON public.bom_history
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END
$$;

GRANT SELECT, INSERT ON public.bom_history TO authenticated;

-- 3. Backfill existing approved BOMs --------------------------------
-- One synthetic "approved" event per approved BOM that has no history,
-- dated at its last revision so the timeline is not blank.
INSERT INTO public.bom_history
  (bom_id, action, from_status, to_status, actor, revision_number, created_at)
SELECT
  b.id::text,
  'approved',
  NULL,
  'approved',
  COALESCE(NULLIF(b.revised_by, ''), NULLIF(b.locked_by, ''), 'Unknown'),
  b.revision_number,
  COALESCE(b.revised_at, now())
FROM public.boms b
WHERE b.bom_status = 'approved'
  AND NOT EXISTS (
    SELECT 1 FROM public.bom_history h WHERE h.bom_id = b.id::text
  );
