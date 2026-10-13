-- Finished stock: a pick order deducts stock as its own movement type,
-- so history can show Picked separately from a one-off sale.
-- Idempotent.

alter table public.finished_stock_movements
  drop constraint if exists finished_stock_movements_type_chk;

alter table public.finished_stock_movements
  add constraint finished_stock_movements_type_chk
    check (movement_type in ('goods_in', 'adjust', 'zero_out', 'sale', 'transfer', 'pick'));
