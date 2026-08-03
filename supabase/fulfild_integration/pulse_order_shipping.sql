-- ============================================================
-- FULFILD SIDE — run this in the Fulfild Supabase project (NOT Pulse).
--
-- Gives Pulse a stable, least-privilege read surface for actual booked
-- shipping cost. Pulse's ecommerce-sync edge function connects with a
-- read-only role and queries ONLY the view below.
--
-- Contract consumed by Pulse (do not rename columns without telling Pulse):
--   external_order_id, order_number, platform, carrier, service,
--   weight_kg, cost, currency, created_at, dispatched_at
--
-- Semantics (agreed with Pulse):
--   * cost      = shipments.cost  -> the chosen rate at label-booking time
--                 (NOT orders.shipping_cost, which is customer-paid and may be
--                 overwritten; NOT a reconciled carrier invoice).
--   * carrier   = shipments.carrier_code (e.g. 'ups', 'dpd').
--   * one row per order = its latest shipment.
-- ============================================================

-- 1) View: orders + latest shipment + store, exposing only what Pulse needs.
create or replace view public.pulse_order_shipping as
select
  o.external_order_id,
  o.order_number,
  s.platform,
  sh.carrier_code            as carrier,
  sh.service                 as service,
  sh.weight_kg               as weight_kg,
  sh.cost                    as cost,
  sh.currency                as currency,
  o.created_at               as created_at,
  o.dispatched_at            as dispatched_at
from public.orders o
join public.stores s on s.id = o.store_id
left join lateral (
  select carrier_code, service, weight_kg, cost, currency
  from public.shipments
  where shipments.order_id = o.id
  order by created_at desc
  limit 1
) sh on true;

-- 2) Read-only role for Pulse. Set a strong password (or use a Supabase pooled
--    connection string for this role). Grant SELECT on the view only.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pulse_readonly') then
    create role pulse_readonly login password 'CHANGE_ME_STRONG_PASSWORD';
  end if;
end $$;

grant usage on schema public to pulse_readonly;
grant select on public.pulse_order_shipping to pulse_readonly;

-- Do NOT grant any other table. Verify with:
--   set role pulse_readonly;  select * from public.pulse_order_shipping limit 1;  reset role;

-- 3) Hand Pulse the pooled connection string for pulse_readonly, e.g.:
--   postgresql://pulse_readonly:<password>@<PROJECT>.pooler.supabase.com:6543/postgres
-- Pulse stores it as the edge secret FULFILD_DB_URL.
