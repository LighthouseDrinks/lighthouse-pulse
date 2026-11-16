-- Finished goods pallets. The job stores the count only. A person on the
-- pallet tracker later adds them to storage, or marks them dispatched.
-- Nothing is posted automatically.

alter table public.jobs
  add column if not exists finished_pallets int,
  add column if not exists finished_pallets_disposition text,
  add column if not exists finished_pallets_decided_at timestamptz,
  add column if not exists finished_pallets_decided_by text;

alter table public.jobs drop constraint if exists jobs_finished_pallets_chk;
alter table public.jobs add constraint jobs_finished_pallets_chk
  check (finished_pallets is null or finished_pallets >= 0);

alter table public.jobs drop constraint if exists jobs_finished_pallets_disposition_chk;
alter table public.jobs add constraint jobs_finished_pallets_disposition_chk
  check (finished_pallets_disposition is null or finished_pallets_disposition in ('stored', 'dispatched'));

alter table public.pallet_accounts
  add column if not exists opening_finished int not null default 0,
  add column if not exists finished_weekly_rate numeric;

alter table public.pallet_accounts drop constraint if exists pallet_accounts_opening_finished_chk;
alter table public.pallet_accounts add constraint pallet_accounts_opening_finished_chk
  check (opening_finished >= 0);

alter table public.pallet_accounts drop constraint if exists pallet_accounts_finished_weekly_rate_chk;
alter table public.pallet_accounts add constraint pallet_accounts_finished_weekly_rate_chk
  check (finished_weekly_rate is null or finished_weekly_rate >= 0);

alter table public.pallet_movements drop constraint if exists pallet_movements_pallet_kind_chk;
alter table public.pallet_movements add constraint pallet_movements_pallet_kind_chk
  check (pallet_kind is null or pallet_kind in ('dry', 'liquid', 'finished'));

alter table public.pallet_billing_periods
  add column if not exists finished_pallet_weeks int,
  add column if not exists finished_weekly_rate numeric,
  add column if not exists finished_amount numeric;

drop view if exists public.pallet_balances;
create view public.pallet_balances
  with (security_invoker = on) as
select
  a.client_id,
  a.opening_pallets,
  a.opening_dry,
  a.opening_liquid,
  a.opening_finished,
  greatest(a.opening_pallets - a.opening_dry - a.opening_liquid - a.opening_finished, 0) as opening_other,
  a.opening_date,
  a.weekly_rate,
  a.dry_weekly_rate,
  a.liquid_weekly_rate,
  a.finished_weekly_rate,
  a.is_active,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'pallet_in'), 0)   as total_in,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'pallet_out'), 0) as total_out,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'used'), 0)       as total_used,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'adjustment'), 0)  as total_adjust,
  a.opening_pallets + coalesce(sum(m.quantity), 0)                            as current_pallets,
  a.opening_dry + coalesce(sum(m.quantity) filter (where m.pallet_kind = 'dry'), 0)           as current_dry,
  a.opening_liquid + coalesce(sum(m.quantity) filter (where m.pallet_kind = 'liquid'), 0)     as current_liquid,
  a.opening_finished + coalesce(sum(m.quantity) filter (where m.pallet_kind = 'finished'), 0) as current_finished,
  greatest(a.opening_pallets - a.opening_dry - a.opening_liquid - a.opening_finished, 0)
    + coalesce(sum(m.quantity) filter (where m.pallet_kind is null), 0)                       as current_other,
  max(m.movement_date)                                                                        as last_movement_date
from public.pallet_accounts a
left join public.pallet_movements m on m.client_id = a.client_id
group by a.client_id, a.opening_pallets, a.opening_dry, a.opening_liquid, a.opening_finished, a.opening_date,
         a.weekly_rate, a.dry_weekly_rate, a.liquid_weekly_rate, a.finished_weekly_rate, a.is_active;

grant select on public.pallet_balances to authenticated;

drop function if exists public.pallet_billing_month(date);

create function public.pallet_billing_month(period_start date)
returns table (
  client_id               text,
  weeks_count             int,
  pallet_weeks            bigint,
  dry_pallet_weeks        bigint,
  liquid_pallet_weeks     bigint,
  finished_pallet_weeks   bigint,
  other_pallet_weeks      bigint,
  week_breakdown          jsonb,
  weekly_rate             numeric,
  dry_weekly_rate         numeric,
  liquid_weekly_rate      numeric,
  finished_weekly_rate    numeric,
  amount                  numeric,
  dry_amount              numeric,
  liquid_amount           numeric,
  finished_amount         numeric,
  other_amount            numeric
)
language sql stable security invoker
set search_path = public as $$
  with bounds as (
    select date_trunc('month', period_start)::date as ms,
           (date_trunc('month', period_start) + interval '1 month - 1 day')::date as me
  ),
  mondays as (
    select d::date as monday
    from bounds, generate_series(bounds.ms, bounds.me, interval '1 day') as d
    where extract(isodow from d) = 1
  ),
  acct as (
    select a.client_id,
           a.opening_dry,
           a.opening_liquid,
           a.opening_finished,
           greatest(a.opening_pallets - a.opening_dry - a.opening_liquid - a.opening_finished, 0) as opening_other,
           a.weekly_rate,
           coalesce(a.dry_weekly_rate, a.weekly_rate)      as dry_rate,
           coalesce(a.liquid_weekly_rate, a.weekly_rate)   as liquid_rate,
           coalesce(a.finished_weekly_rate, a.weekly_rate) as finished_rate
    from public.pallet_accounts a
    where a.is_active
  ),
  weekly as (
    select ac.client_id, ac.weekly_rate, ac.dry_rate, ac.liquid_rate, ac.finished_rate, mo.monday,
           greatest(
             ac.opening_dry + coalesce((
               select sum(m.quantity) from public.pallet_movements m
               where m.client_id = ac.client_id
                 and m.pallet_kind = 'dry'
                 and m.movement_date <= mo.monday
             ), 0), 0) as dry_pallets,
           greatest(
             ac.opening_liquid + coalesce((
               select sum(m.quantity) from public.pallet_movements m
               where m.client_id = ac.client_id
                 and m.pallet_kind = 'liquid'
                 and m.movement_date <= mo.monday
             ), 0), 0) as liquid_pallets,
           greatest(
             ac.opening_finished + coalesce((
               select sum(m.quantity) from public.pallet_movements m
               where m.client_id = ac.client_id
                 and m.pallet_kind = 'finished'
                 and m.movement_date <= mo.monday
             ), 0), 0) as finished_pallets,
           greatest(
             ac.opening_other + coalesce((
               select sum(m.quantity) from public.pallet_movements m
               where m.client_id = ac.client_id
                 and m.pallet_kind is null
                 and m.movement_date <= mo.monday
             ), 0), 0) as other_pallets
    from acct ac
    cross join mondays mo
  )
  select
    w.client_id,
    count(*)::int as weeks_count,
    sum(w.dry_pallets + w.liquid_pallets + w.finished_pallets + w.other_pallets)::bigint as pallet_weeks,
    sum(w.dry_pallets)::bigint      as dry_pallet_weeks,
    sum(w.liquid_pallets)::bigint   as liquid_pallet_weeks,
    sum(w.finished_pallets)::bigint as finished_pallet_weeks,
    sum(w.other_pallets)::bigint    as other_pallet_weeks,
    jsonb_agg(
      jsonb_build_object(
        'date', w.monday,
        'pallets', w.dry_pallets + w.liquid_pallets + w.finished_pallets + w.other_pallets,
        'dry', w.dry_pallets,
        'liquid', w.liquid_pallets,
        'finished', w.finished_pallets,
        'other', w.other_pallets
      ) order by w.monday
    ) as week_breakdown,
    max(w.weekly_rate)   as weekly_rate,
    max(w.dry_rate)      as dry_weekly_rate,
    max(w.liquid_rate)   as liquid_weekly_rate,
    max(w.finished_rate) as finished_weekly_rate,
    round(
      sum(w.dry_pallets)      * coalesce(max(w.dry_rate), 0)
      + sum(w.liquid_pallets) * coalesce(max(w.liquid_rate), 0)
      + sum(w.finished_pallets) * coalesce(max(w.finished_rate), 0)
      + sum(w.other_pallets)  * coalesce(max(w.weekly_rate), 0)
    , 2) as amount,
    round(sum(w.dry_pallets) * coalesce(max(w.dry_rate), 0), 2)             as dry_amount,
    round(sum(w.liquid_pallets) * coalesce(max(w.liquid_rate), 0), 2)       as liquid_amount,
    round(sum(w.finished_pallets) * coalesce(max(w.finished_rate), 0), 2)   as finished_amount,
    round(sum(w.other_pallets) * coalesce(max(w.weekly_rate), 0), 2)        as other_amount
  from weekly w
  group by w.client_id;
$$;

revoke all on function public.pallet_billing_month(date) from public, anon;
grant execute on function public.pallet_billing_month(date) to authenticated;
