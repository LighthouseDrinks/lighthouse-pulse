-- ============================================================
-- liquid_history: performance indexes.
--
-- liquid_history previously had only its primary-key index. The two
-- hottest access patterns have no supporting index:
--   1. Container detail / audit view:
--        ?container_id=eq.<id>&order=created_at.desc
--   2. Grouped movements (blend / transfer / disgorge / close-out)
--        joined by event_group_id.
-- As the table grows these degrade into full scans.
--
-- This migration adds a composite (container_id, created_at DESC)
-- index for the per-container history query, and a (event_group_id)
-- index for grouped lookups (partial: only rows that carry a group).
--
-- Safe to re-run: CREATE INDEX IF NOT EXISTS is idempotent. The table
-- is small so the build is effectively instant; no data is changed.
-- ============================================================

CREATE INDEX IF NOT EXISTS liquid_history_container_created_idx
  ON public.liquid_history (container_id, created_at DESC);

CREATE INDEX IF NOT EXISTS liquid_history_event_group_idx
  ON public.liquid_history (event_group_id)
  WHERE event_group_id IS NOT NULL;
