-- ============================================================
-- Job-specific temporary SKUs
--
-- A temporary SKU is attached to one job's supply-chain snapshot
-- (job_components) and never written to the saved BOM. Completion
-- deducts it from the owning client's stock. A durable ledger
-- (temporary_sku_usage) records every deduction so borrowed stock
-- cannot be forgotten if the job's component rows are later wiped.
--
-- Idempotent / safe to re-run.
-- ============================================================

ALTER TABLE public.job_components
  ADD COLUMN IF NOT EXISTS is_temporary boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.temporary_sku_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id text NOT NULL,
  sku_id text NOT NULL,
  job_client_id text,
  sku_owner_client_id text,
  qty_required numeric,
  qty_deducted numeric NOT NULL DEFAULT 0,
  waste_qty numeric NOT NULL DEFAULT 0,
  deducted_at timestamptz NOT NULL DEFAULT now(),
  deducted_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_id, sku_id)
);

CREATE INDEX IF NOT EXISTS temporary_sku_usage_deducted_at_idx
  ON public.temporary_sku_usage (deducted_at DESC);
CREATE INDEX IF NOT EXISTS temporary_sku_usage_sku_owner_idx
  ON public.temporary_sku_usage (sku_owner_client_id);
CREATE INDEX IF NOT EXISTS temporary_sku_usage_job_client_idx
  ON public.temporary_sku_usage (job_client_id);

ALTER TABLE public.temporary_sku_usage ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_all ON public.temporary_sku_usage;
CREATE POLICY staff_all ON public.temporary_sku_usage
  FOR ALL TO authenticated
  USING (public.is_staff())
  WITH CHECK (public.is_staff());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.temporary_sku_usage TO authenticated;
GRANT ALL ON public.temporary_sku_usage TO service_role;
