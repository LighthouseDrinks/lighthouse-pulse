-- Finished stock: SKU location + sale/transfer movement types.
-- Idempotent.

alter table public.finished_stock_products
  add column if not exists location text;

alter table public.finished_stock_movements
  drop constraint if exists finished_stock_movements_type_chk;

alter table public.finished_stock_movements
  add constraint finished_stock_movements_type_chk
    check (movement_type in ('goods_in', 'adjust', 'zero_out', 'sale', 'transfer'));
