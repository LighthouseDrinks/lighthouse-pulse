-- ============================================================
-- Ecommerce / 3PL — store RRP (ex-VAT) per SKU
--
-- Builds on ecommerce_3pl_stores_and_po.sql. Captures each
-- product's regular retail price from the linked store, with
-- Irish VAT (23%) stripped. Refreshed on every product sync
-- (store-of-record data — unlike purchase_price/volume_ml/abv
-- which are set by us and preserved).
--
-- Cash difference and gross-margin % are derived in the UI from
-- rrp_ex_vat and purchase_price, so they are not stored.
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

alter table public.three_pl_client_products
  add column if not exists rrp_ex_vat numeric;
