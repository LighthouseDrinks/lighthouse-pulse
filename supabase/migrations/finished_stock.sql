-- Finished bottled stock — Lighthouse-owned bottled goods
-- Product catalogue + on-hand lots (location, qty, cost/case) + movement audit.
-- Quantity is stored as bottles; the UI displays warehouse cases.bottles form
-- (100 six-bottle cases + 3 loose = 100.03).
--
-- Idempotent: safe to re-run. Applied via Supabase (MCP / dashboard).

-- ── Products ────────────────────────────────────────────────────────────────
create table if not exists public.finished_stock_products (
  id                 text primary key,
  name               text not null,
  sku                text,
  bottles_per_case   integer not null default 6 check (bottles_per_case >= 1),
  default_unit_cost  numeric,
  notes              text,
  is_active          boolean not null default true,
  created_by         text,
  created_at         timestamptz not null default now()
);

create unique index if not exists finished_stock_products_name_active
  on public.finished_stock_products (lower(name))
  where is_active = true;

create index if not exists finished_stock_products_active
  on public.finished_stock_products (is_active, name);

-- ── Lots ────────────────────────────────────────────────────────────────────
create table if not exists public.finished_stock_lots (
  id                uuid primary key default gen_random_uuid(),
  product_id        text not null references public.finished_stock_products(id) on delete restrict,
  location          text,
  quantity_bottles  integer not null default 0 check (quantity_bottles >= 0),
  unit_cost         numeric,
  notes             text,
  updated_by        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists finished_stock_lots_product
  on public.finished_stock_lots (product_id);

create index if not exists finished_stock_lots_qty
  on public.finished_stock_lots (quantity_bottles);

-- ── Movements ───────────────────────────────────────────────────────────────
create table if not exists public.finished_stock_movements (
  id                uuid primary key default gen_random_uuid(),
  product_id        text not null references public.finished_stock_products(id) on delete restrict,
  lot_id            uuid references public.finished_stock_lots(id) on delete set null,
  movement_type     text not null,
  quantity_bottles  integer not null,
  location          text,
  unit_cost         numeric,
  notes             text,
  performed_by      text,
  created_at        timestamptz not null default now(),
  constraint finished_stock_movements_type_chk
    check (movement_type in ('goods_in', 'adjust', 'zero_out'))
);

create index if not exists finished_stock_movements_product
  on public.finished_stock_movements (product_id, created_at desc);

-- ── Seed named LH products (case size editable in-app) ──────────────────────
insert into public.finished_stock_products (id, name, sku, bottles_per_case)
select 'FS-001', 'Hide Number 3', 'HIDE-03', 6
where not exists (select 1 from public.finished_stock_products where id = 'FS-001');

insert into public.finished_stock_products (id, name, sku, bottles_per_case)
select 'FS-002', 'Hide Number 4', 'HIDE-04', 6
where not exists (select 1 from public.finished_stock_products where id = 'FS-002');

insert into public.finished_stock_products (id, name, sku, bottles_per_case)
select 'FS-003', 'Hide Number 5', 'HIDE-05', 6
where not exists (select 1 from public.finished_stock_products where id = 'FS-003');

insert into public.finished_stock_products (id, name, sku, bottles_per_case)
select 'FS-004', 'Agaris Irish Whiskey', 'AGARIS', 6
where not exists (select 1 from public.finished_stock_products where id = 'FS-004');

-- ── Permission: same roles that can edit dry goods ──────────────────────────
update public.roles
   set permissions = permissions || jsonb_build_object(
         'finished_stock_edit',
         case when coalesce((permissions->>'drygoods_edit')::int, 0) = 1 then 1 else 0 end
       ),
       updated_at = now()
 where permissions is not null
   and permissions <> '{}'::jsonb
   and not (permissions ? 'finished_stock_edit');

-- ── RLS: staff only ─────────────────────────────────────────────────────────
alter table public.finished_stock_products   enable row level security;
alter table public.finished_stock_lots       enable row level security;
alter table public.finished_stock_movements  enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'finished_stock_products'
       and policyname = 'staff_all_finished_stock_products'
  ) then
    create policy staff_all_finished_stock_products on public.finished_stock_products
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'finished_stock_lots'
       and policyname = 'staff_all_finished_stock_lots'
  ) then
    create policy staff_all_finished_stock_lots on public.finished_stock_lots
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'finished_stock_movements'
       and policyname = 'staff_all_finished_stock_movements'
  ) then
    create policy staff_all_finished_stock_movements on public.finished_stock_movements
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
end
$$;

revoke insert, update, delete, truncate, references, trigger on public.finished_stock_products  from anon;
revoke insert, update, delete, truncate, references, trigger on public.finished_stock_lots      from anon;
revoke insert, update, delete, truncate, references, trigger on public.finished_stock_movements from anon;
revoke truncate, references, trigger on public.finished_stock_products  from authenticated;
revoke truncate, references, trigger on public.finished_stock_lots      from authenticated;
revoke truncate, references, trigger on public.finished_stock_movements from authenticated;
