-- ============================================================
-- BOM approval snapshot columns (patch)
-- Stores product/client name and full BOM component data
-- in the approval record so the public magic-link page can
-- display it without needing access to other tables.
-- ============================================================

ALTER TABLE job_bom_approvals
  ADD COLUMN IF NOT EXISTS product_name TEXT,
  ADD COLUMN IF NOT EXISTS client_name  TEXT,
  ADD COLUMN IF NOT EXISTS bom_snapshot JSONB;
