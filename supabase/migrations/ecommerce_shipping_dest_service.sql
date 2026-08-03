-- ============================================================
-- Ecommerce / Shipping — richer destination + service capture
--
-- Extends ecommerce_shipping_costs.sql. To make UPS quotes mirror the
-- real label, we capture per order the full destination (street lines,
-- name, company, residential flag) and the shipping service used, on top
-- of the city/postal/country/weight columns added previously.
--
-- Idempotent / safe to re-run.
-- ============================================================

alter table public.ecommerce_orders
  add column if not exists ship_name         text,
  add column if not exists ship_company      text,
  add column if not exists ship_address1     text,
  add column if not exists ship_address2     text,
  add column if not exists ship_residential  boolean,
  add column if not exists ship_service_name text,
  add column if not exists ship_service_code text;
