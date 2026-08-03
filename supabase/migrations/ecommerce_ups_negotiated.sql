-- ============================================================
-- Ecommerce / Shipping — UPS quote rate type
--
-- For orders costed via a live UPS quote (carrier_cost_source = 'ups_quote'),
-- records whether the rate UPS returned was account-negotiated (discount
-- applied) or the published/list rate. Cached alongside ups_cost so the
-- Shipping Cost Report can show the distinction without re-quoting.
--
--   ups_negotiated  — true = negotiated rate, false = published/list,
--                     null  = not a UPS quote / rate type unknown
--
-- Idempotent / safe to re-run.
-- ============================================================

alter table public.ecommerce_orders
  add column if not exists ups_negotiated boolean;
