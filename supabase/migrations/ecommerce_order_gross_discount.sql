-- Accurate ex-VAT gross + discount capture per order line, plus itemised
-- coupon/promo detail per order (sourced from each store's own at-sale prices).
alter table public.ecommerce_order_items
  add column if not exists gross_ex_vat    numeric,   -- pre-discount line value, ex-VAT
  add column if not exists discount_ex_vat numeric;   -- ex-VAT discount on the line (gross - net)

alter table public.ecommerce_orders
  add column if not exists discounts jsonb;            -- [{ code, type, amount_ex_vat }, ...]
