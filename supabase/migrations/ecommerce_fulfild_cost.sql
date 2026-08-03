-- ============================================================
-- Ecommerce / Shipping — Fulfild actual cost cache
--
-- Fulfild (the fulfilment platform) is the source of truth for the actual
-- booked carrier cost. The shipping_cost_report action reads Fulfild's
-- pulse_order_shipping view and caches the resolved cost + its provenance
-- here so re-runs are fast and stable.
--
--   carrier_cost         — resolved shipping cost for the order
--   carrier_cost_source  — where it came from: 'fulfild' | 'ups_quote' | 'dpd_flat'
--
-- Idempotent / safe to re-run.
-- ============================================================

alter table public.ecommerce_orders
  add column if not exists carrier_cost        numeric,
  add column if not exists carrier_cost_source text;
