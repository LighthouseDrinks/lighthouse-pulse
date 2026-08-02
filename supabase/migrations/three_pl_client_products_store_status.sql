-- Track each product's publish/for-sale status on the source store, plus a
-- user-controlled toggle for whether it should be listed and included in POs.
alter table public.three_pl_client_products
  add column if not exists store_status text,                       -- store status, e.g. 'active' / 'draft' / 'archived' / 'publish'
  add column if not exists included      boolean not null default true;  -- user toggle: show (checked) and include in POs
