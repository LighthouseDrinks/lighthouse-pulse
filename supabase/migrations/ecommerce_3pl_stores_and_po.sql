-- ============================================================
-- Ecommerce / 3PL — store links, product catalogue, purchase orders
--
-- Builds on ecommerce_3pl_clients.sql. Lets each 3PL client link a
-- Shopify/WooCommerce store (reusing ecommerce_stores + the
-- ecommerce-sync edge function), hold our purchase price per SKU,
-- and generate purchase orders by one of two methods:
--   'purchase_price' — qty sold x our preset purchase price per SKU
--   'discount'       — total net sales x (1 - discount %)
--
-- Also adds ex-VAT net sales capture to ecommerce_order_items so the
-- SKU report can show prices ex-VAT. All staff may read; connect/sync
-- of stores is enforced in the edge function (finance/admin only).
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

-- ── three_pl_clients: PO configuration ─────────────────────
alter table public.three_pl_clients
  add column if not exists po_method       text default 'purchase_price',
  add column if not exists po_discount_pct numeric;

-- ── Product catalogue + our purchase price per SKU ─────────
create table if not exists public.three_pl_client_products (
  id                  uuid primary key default gen_random_uuid(),
  three_pl_client_id  uuid not null references public.three_pl_clients(id) on delete cascade,
  sku                 text,
  product_name        text not null,
  external_id         text,
  purchase_price      numeric,          -- our price, set by us; preserved on re-sync
  currency            text default 'EUR',
  active              boolean not null default true,
  last_seen_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- One catalogue row per (client, sku). Partial unique index so rows
-- without a SKU are still allowed (matched by product_name in the UI).
create unique index if not exists uq_three_pl_client_products_client_sku
  on public.three_pl_client_products(three_pl_client_id, sku)
  where sku is not null;
create index if not exists idx_three_pl_client_products_client
  on public.three_pl_client_products(three_pl_client_id);

grant select, insert, update, delete on public.three_pl_client_products to authenticated;
grant all on public.three_pl_client_products to service_role;

alter table public.three_pl_client_products enable row level security;

drop policy if exists three_pl_client_products_select on public.three_pl_client_products;
create policy three_pl_client_products_select on public.three_pl_client_products
  for select to authenticated using (public.is_staff());

drop policy if exists three_pl_client_products_write on public.three_pl_client_products;
create policy three_pl_client_products_write on public.three_pl_client_products
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- ── Link stores to a 3PL client ────────────────────────────
alter table public.ecommerce_stores
  add column if not exists three_pl_client_id uuid references public.three_pl_clients(id) on delete set null;
create index if not exists idx_ecommerce_stores_three_pl_client
  on public.ecommerce_stores(three_pl_client_id);

-- Expose the link on the public (credential-free) view.
create or replace view public.ecommerce_stores_public as
  select
    id, name, platform, store_url, is_active,
    created_at, created_by, updated_at,
    connection_status, last_synced_at, orders_synced_count,
    revenue_synced, error_message, sync_from_date,
    xero_sales_account, xero_shipping_account,
    three_pl_client_id
  from public.ecommerce_stores
  where is_active = true;
-- Definer behaviour (security_invoker OFF): the view is credential-free and
-- SELECT on the base ecommerce_stores table is revoked from authenticated, so
-- the view must run with its owner's privileges (matches the original design).
alter view public.ecommerce_stores_public set (security_invoker = off);
revoke all on public.ecommerce_stores_public from anon;
grant select on public.ecommerce_stores_public to authenticated;

-- ── ex-VAT sales capture on order items ────────────────────
alter table public.ecommerce_order_items
  add column if not exists tax_amount numeric,
  add column if not exists net_sales  numeric;   -- ex-VAT, net of discount, per product line

alter table public.ecommerce_orders
  add column if not exists taxes_included boolean;

-- ── Purchase orders ────────────────────────────────────────
create table if not exists public.three_pl_purchase_orders (
  id                  uuid primary key default gen_random_uuid(),
  three_pl_client_id  uuid not null references public.three_pl_clients(id) on delete cascade,
  po_number           text,
  period_start        date,
  period_end          date,
  method              text,            -- 'purchase_price' | 'discount'
  discount_pct        numeric,         -- method 'discount' only
  currency            text default 'EUR',
  subtotal_net        numeric,         -- total ex-VAT net sales for the period
  total               numeric,         -- PO total
  notes               text,
  status              text default 'generated',
  created_at          timestamptz not null default now(),
  created_by          uuid
);
create index if not exists idx_three_pl_po_client on public.three_pl_purchase_orders(three_pl_client_id);

create table if not exists public.three_pl_purchase_order_lines (
  id             uuid primary key default gen_random_uuid(),
  po_id          uuid not null references public.three_pl_purchase_orders(id) on delete cascade,
  sku            text,
  product_name   text,
  quantity       numeric,
  net_sales      numeric,         -- ex-VAT net sales for this SKU in the period
  purchase_price numeric,         -- method 'purchase_price': our unit price
  po_unit_price  numeric,         -- effective PO unit price under the chosen method
  po_line_total  numeric
);
create index if not exists idx_three_pl_po_lines_po on public.three_pl_purchase_order_lines(po_id);

grant select, insert, update, delete
  on public.three_pl_purchase_orders, public.three_pl_purchase_order_lines to authenticated;
grant all
  on public.three_pl_purchase_orders, public.three_pl_purchase_order_lines to service_role;

alter table public.three_pl_purchase_orders      enable row level security;
alter table public.three_pl_purchase_order_lines enable row level security;

drop policy if exists three_pl_po_select on public.three_pl_purchase_orders;
create policy three_pl_po_select on public.three_pl_purchase_orders
  for select to authenticated using (public.is_staff());
drop policy if exists three_pl_po_write on public.three_pl_purchase_orders;
create policy three_pl_po_write on public.three_pl_purchase_orders
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists three_pl_po_lines_select on public.three_pl_purchase_order_lines;
create policy three_pl_po_lines_select on public.three_pl_purchase_order_lines
  for select to authenticated using (public.is_staff());
drop policy if exists three_pl_po_lines_write on public.three_pl_purchase_order_lines;
create policy three_pl_po_lines_write on public.three_pl_purchase_order_lines
  for all to authenticated using (public.is_staff()) with check (public.is_staff());
