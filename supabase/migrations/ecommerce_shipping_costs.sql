-- ============================================================
-- Ecommerce / Shipping — per-order shipping cost reporting
--
-- Adds the fields needed to work out what a shipment cost:
--   * shipping destination (country/postal/city/state) + weight, so UPS
--     orders can be rated via the UPS Rating API in the edge function.
--   * detected_carrier + ups_cost, a cache written back by the
--     `shipping_cost_report` action so re-runs are fast and stable.
--
-- Also seeds a default `shipping_config` row in app_settings holding:
--   * dpd_ie_flat_rate  — flat DPD Ireland cost applied to every DPD order
--   * carrier_rules     — shipping-method title keyword -> carrier mapping
--   * ups               — non-secret UPS config (account, origin, service)
-- UPS OAuth client_id/secret live as edge-function env secrets, not here.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── ecommerce_orders: shipping destination, weight, cost cache ──
alter table public.ecommerce_orders
  add column if not exists ship_country       text,
  add column if not exists ship_postal        text,
  add column if not exists ship_city          text,
  add column if not exists ship_state         text,
  add column if not exists total_weight_grams numeric,
  add column if not exists detected_carrier   text,
  add column if not exists ups_cost           numeric;

-- ── Seed default shipping_config (staff-managed via the Shipping tab) ──
-- app_settings.value is text; we store JSON as a string (matches the
-- working_day_overrides convention). Only insert if absent so re-runs and
-- later edits from the UI are preserved.
insert into public.app_settings (key, value)
select
  'shipping_config',
  '{"dpd_ie_flat_rate":null,"carrier_rules":[{"keyword":"dpd","carrier":"dpd"},{"keyword":"ups","carrier":"ups"}],"ups":{"account_number":"","service_code":"11","default_weight_kg":1,"origin":{"city":"","postal":"","country":"IE","state":""}}}'
where not exists (
  select 1 from public.app_settings where key = 'shipping_config'
);
