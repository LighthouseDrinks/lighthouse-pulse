-- Finished stock: who owns each lot. Value reporting uses lighthouse only.
-- Idempotent.

alter table public.finished_stock_lots
  add column if not exists owner text;

update public.finished_stock_lots
   set owner = 'lighthouse'
 where owner is null;

alter table public.finished_stock_lots
  alter column owner set not null;

alter table public.finished_stock_lots
  drop constraint if exists finished_stock_lots_owner_chk;

alter table public.finished_stock_lots
  add constraint finished_stock_lots_owner_chk
  check (owner in ('lighthouse', 'hibernia'));

alter table public.finished_stock_movements
  add column if not exists owner text;

update public.finished_stock_movements
   set owner = 'lighthouse'
 where owner is null;

alter table public.finished_stock_movements
  alter column owner set not null;

alter table public.finished_stock_movements
  drop constraint if exists finished_stock_movements_owner_chk;

alter table public.finished_stock_movements
  add constraint finished_stock_movements_owner_chk
  check (owner in ('lighthouse', 'hibernia'));
