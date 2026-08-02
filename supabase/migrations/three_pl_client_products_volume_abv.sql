-- ============================================================
-- Ecommerce / 3PL — per-SKU volume & ABV for excise duty
--
-- Builds on ecommerce_3pl_stores_and_po.sql. Adds volume (ml) and
-- ABV (%) to each purchase-price row so the UI can auto-calculate
-- the Alcohol Products Tax (excise) per unit. Excise itself is
-- derived on the fly (volume_ml/1000 * abv/100 * spirits APT rate),
-- so it is NOT stored.
--
-- These are set by us, like purchase_price, and are preserved on
-- product re-sync (the ecommerce-sync edge function never writes
-- them on update).
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

alter table public.three_pl_client_products
  add column if not exists volume_ml numeric,   -- unit volume in millilitres
  add column if not exists abv       numeric;    -- alcohol by volume, as a percentage
