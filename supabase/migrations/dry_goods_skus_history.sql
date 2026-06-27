-- ============================================================
-- dry_goods_skus_history: audit trail for dry goods SKU lifecycle.
--
-- The dry_goods_skus table only stamps created_by / created_at, so
-- the app could show who *created* a SKU but never who edited or
-- deactivated it. This table records one immutable row per lifecycle
-- action (created / edited / deactivated / reactivated / deleted),
-- written app-side via _skuRecordHistory() using the logged-in user's
-- session — mirroring the convention already used by bom_history and
-- vessel_history.
--
-- sku_id is TEXT to match dry_goods_skus.id (codes like 'SKU-288').
-- `changes` holds a field-level { field: { from, to } } JSON diff for
-- edits; it is null for create/deactivate events.
--
-- Safe to re-run: table/columns/index/policies are guarded, and the
-- backfill only inserts a synthetic 'created' event for SKUs that
-- don't already have one.
-- ============================================================

-- 1. Table + columns ------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dry_goods_skus_history (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_id      text NOT NULL,
  action      text NOT NULL,
  actor       text,
  changes     jsonb,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Additive guards in case an older/partial table already exists.
ALTER TABLE public.dry_goods_skus_history
  ADD COLUMN IF NOT EXISTS sku_id     text,
  ADD COLUMN IF NOT EXISTS action     text,
  ADD COLUMN IF NOT EXISTS actor      text,
  ADD COLUMN IF NOT EXISTS changes    jsonb,
  ADD COLUMN IF NOT EXISTS note       text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

-- Fast lookup for the UI query: ?sku_id=eq.<id>&order=created_at.desc
CREATE INDEX IF NOT EXISTS dry_goods_skus_history_sku_id_created_at_idx
  ON public.dry_goods_skus_history (sku_id, created_at DESC);

-- 2. RLS + policies -------------------------------------------------
ALTER TABLE public.dry_goods_skus_history ENABLE ROW LEVEL SECURITY;

-- Permissive read/write for any authenticated session, matching the
-- app-table convention (bom_history / client_invoice_rates). CREATE
-- POLICY has no IF NOT EXISTS, so guard it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'dry_goods_skus_history'
       AND policyname = 'dry_goods_skus_history_auth_all'
  ) THEN
    CREATE POLICY "dry_goods_skus_history_auth_all" ON public.dry_goods_skus_history
      FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END
$$;

GRANT SELECT, INSERT ON public.dry_goods_skus_history TO authenticated;

-- 3. Backfill 'created' events for existing SKUs --------------------
-- One synthetic 'created' event per SKU that has no history yet, using
-- the existing created_by / created_at so the timeline is not blank.
INSERT INTO public.dry_goods_skus_history (sku_id, action, actor, created_at)
SELECT
  s.id,
  'created',
  COALESCE(NULLIF(s.created_by, ''), 'Unknown'),
  COALESCE(s.created_at, now())
FROM public.dry_goods_skus s
WHERE NOT EXISTS (
  SELECT 1 FROM public.dry_goods_skus_history h
   WHERE h.sku_id = s.id AND h.action = 'created'
);
