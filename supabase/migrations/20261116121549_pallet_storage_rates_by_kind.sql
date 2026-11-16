-- ============================================================
-- Pallet storage rates by kind
--
-- Some clients are charged a different weekly rate for a dry-goods
-- pallet than for a liquid pallet. Balances and Monday billing
-- snapshots are therefore kept per kind:
--   dry, liquid, and unclassified (opening stock or older movements
--   that were never tagged).
--
-- A side with no rate of its own uses pallet_accounts.weekly_rate.
-- Unclassified pallets use weekly_rate only, so a split rate is never
-- applied to stock we cannot place.
-- ============================================================

alter table public.pallet_accounts
  add column if not exists opening_dry       int not null default 0,
  add column if not exists opening_liquid    int not null default 0,
  add column if not exists dry_weekly_rate   numeric,
  add column if not exists liquid_weekly_rate numeric;

alter table public.pallet_accounts
  drop constraint if exists pallet_accounts_opening_kind_chk;
alter table public.pallet_accounts
  add constraint pallet_accounts_opening_kind_chk
  check (opening_dry >= 0 and opening_liquid >= 0);

-- Copy the existing single rate onto both sides. weekly_rate stays,
-- and remains the rate for unclassified pallets.
update public.pallet_accounts
   set dry_weekly_rate    = coalesce(dry_weekly_rate, weekly_rate),
       liquid_weekly_rate = coalesce(liquid_weekly_rate, weekly_rate)
 where weekly_rate is not null
   and (dry_weekly_rate is null or liquid_weekly_rate is null);

alter table public.pallet_movements
  add column if not exists pallet_kind text;

alter table public.pallet_movements
  drop constraint if exists pallet_movements_pallet_kind_chk;
alter table public.pallet_movements
  add constraint pallet_movements_pallet_kind_chk
  check (pallet_kind is null or pallet_kind in ('dry', 'liquid'));

update public.pallet_movements
   set pallet_kind = 'dry'
 where source = 'dry_goods_batch' and pallet_kind is null;
update public.pallet_movements
   set pallet_kind = 'liquid'
 where source = 'liquid_container' and pallet_kind is null;

-- One captured movement per source record per kind.
drop index if exists public.uq_pallet_movements_source;
create unique index uq_pallet_movements_source
  on public.pallet_movements (source, source_id, pallet_kind)
  where source <> 'manual';

alter table public.jobs
  add column if not exists pallets_used_dry    int,
  add column if not exists pallets_used_liquid int;

-- ── Capture: dry goods delivery -> dry pallet_in ─────────────────
create or replace function public.pallet_capture_batch()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if NEW.pallet_count is not null and NEW.pallet_count > 0 and NEW.client_id is not null then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, pallet_kind, performed_by)
    values
      (NEW.client_id, 'pallet_in', NEW.pallet_count, coalesce(NEW.delivery_date, current_date),
       coalesce(NEW.po_reference, NEW.batch_ref, left(NEW.id::text, 8)),
       'dry_goods_batch', NEW.id::text, 'dry', NEW.received_by)
    on conflict (source, source_id, pallet_kind) where source <> 'manual'
    do update set quantity      = excluded.quantity,
                  movement_date = excluded.movement_date,
                  reference     = excluded.reference,
                  client_id     = excluded.client_id;
  else
    delete from public.pallet_movements
     where source = 'dry_goods_batch' and source_id = NEW.id::text;
  end if;
  return NEW;
end;
$$;
revoke all on function public.pallet_capture_batch() from public, anon, authenticated;

-- ── Capture: liquid intake -> liquid pallet_in ───────────────────
create or replace function public.pallet_capture_container()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if NEW.pallet_count is not null and NEW.pallet_count > 0 and NEW.client_id is not null then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, pallet_kind)
    values
      (NEW.client_id, 'pallet_in', NEW.pallet_count, current_date,
       NEW.reference, 'liquid_container', NEW.id::text, 'liquid')
    on conflict (source, source_id, pallet_kind) where source <> 'manual'
    do update set quantity      = excluded.quantity,
                  reference     = excluded.reference,
                  client_id     = excluded.client_id;
  else
    delete from public.pallet_movements
     where source = 'liquid_container' and source_id = NEW.id::text;
  end if;
  return NEW;
end;
$$;
revoke all on function public.pallet_capture_container() from public, anon, authenticated;

-- ── Capture: job close -> used, split when the job says so ───────
create or replace function public.pallet_capture_job()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_date date := coalesce(NEW.date_completed::date, current_date);
  v_ref  text := 'Job ' || NEW.id::text;
begin
  delete from public.pallet_movements
   where source = 'job'
     and source_id in (NEW.id::text, NEW.id::text || ':dry', NEW.id::text || ':liquid');

  if NEW.client_id is null then
    return NEW;
  end if;

  if NEW.pallets_used_dry is not null or NEW.pallets_used_liquid is not null then
    if coalesce(NEW.pallets_used_dry, 0) > 0 then
      insert into public.pallet_movements
        (client_id, movement_type, quantity, movement_date, reference, source, source_id, pallet_kind, job_id)
      values
        (NEW.client_id, 'used', -NEW.pallets_used_dry, v_date, v_ref, 'job', NEW.id::text || ':dry', 'dry', NEW.id::text);
    end if;
    if coalesce(NEW.pallets_used_liquid, 0) > 0 then
      insert into public.pallet_movements
        (client_id, movement_type, quantity, movement_date, reference, source, source_id, pallet_kind, job_id)
      values
        (NEW.client_id, 'used', -NEW.pallets_used_liquid, v_date, v_ref, 'job', NEW.id::text || ':liquid', 'liquid', NEW.id::text);
    end if;
  elsif NEW.pallets_used is not null and NEW.pallets_used > 0 then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, job_id)
    values
      (NEW.client_id, 'used', -NEW.pallets_used, v_date, v_ref, 'job', NEW.id::text, NEW.id::text);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_pallet_capture_job on public.jobs;
create trigger trg_pallet_capture_job
  after insert or update of pallets_used, pallets_used_dry, pallets_used_liquid on public.jobs
  for each row execute function public.pallet_capture_job();
revoke all on function public.pallet_capture_job() from public, anon, authenticated;

-- ── Balances, split by kind ───────────────────────────────────────
drop view if exists public.pallet_balances;
create view public.pallet_balances
  with (security_invoker = on) as
select
  a.client_id,
  a.opening_pallets,
  a.opening_dry,
  a.opening_liquid,
  greatest(a.opening_pallets - a.opening_dry - a.opening_liquid, 0) as opening_other,
  a.opening_date,
  a.weekly_rate,
  a.dry_weekly_rate,
  a.liquid_weekly_rate,
  a.is_active,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'pallet_in'), 0)   as total_in,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'pallet_out'), 0) as total_out,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'used'), 0)       as total_used,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'adjustment'), 0)  as total_adjust,
  a.opening_pallets + coalesce(sum(m.quantity), 0)                            as current_pallets,
  a.opening_dry + coalesce(sum(m.quantity) filter (where m.pallet_kind = 'dry'), 0)       as current_dry,
  a.opening_liquid + coalesce(sum(m.quantity) filter (where m.pallet_kind = 'liquid'), 0) as current_liquid,
  greatest(a.opening_pallets - a.opening_dry - a.opening_liquid, 0)
    + coalesce(sum(m.quantity) filter (where m.pallet_kind is null), 0)                   as current_other,
  max(m.movement_date)                                                                    as last_movement_date
from public.pallet_accounts a
left join public.pallet_movements m on m.client_id = a.client_id
group by a.client_id, a.opening_pallets, a.opening_dry, a.opening_liquid, a.opening_date,
         a.weekly_rate, a.dry_weekly_rate, a.liquid_weekly_rate, a.is_active;

grant select on public.pallet_balances to authenticated;

-- ── Locked invoice snapshots gain the same split ─────────────────
alter table public.pallet_billing_periods
  add column if not exists dry_pallet_weeks     int,
  add column if not exists liquid_pallet_weeks  int,
  add column if not exists other_pallet_weeks   int,
  add column if not exists dry_weekly_rate      numeric,
  add column if not exists liquid_weekly_rate   numeric,
  add column if not exists dry_amount           numeric,
  add column if not exists liquid_amount        numeric,
  add column if not exists other_amount         numeric;

-- Return shape changes, so replace the function outright.
drop function if exists public.pallet_billing_month(date);

create function public.pallet_billing_month(period_start date)
returns table (
  client_id            text,
  weeks_count          int,
  pallet_weeks         bigint,
  dry_pallet_weeks     bigint,
  liquid_pallet_weeks  bigint,
  other_pallet_weeks   bigint,
  week_breakdown       jsonb,
  weekly_rate          numeric,
  dry_weekly_rate      numeric,
  liquid_weekly_rate   numeric,
  amount               numeric,
  dry_amount           numeric,
  liquid_amount        numeric,
  other_amount         numeric
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
           greatest(a.opening_pallets - a.opening_dry - a.opening_liquid, 0) as opening_other,
           a.weekly_rate,
           coalesce(a.dry_weekly_rate, a.weekly_rate)    as dry_rate,
           coalesce(a.liquid_weekly_rate, a.weekly_rate) as liquid_rate
    from public.pallet_accounts a
    where a.is_active
  ),
  weekly as (
    select ac.client_id, ac.weekly_rate, ac.dry_rate, ac.liquid_rate, mo.monday,
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
    sum(w.dry_pallets + w.liquid_pallets + w.other_pallets)::bigint as pallet_weeks,
    sum(w.dry_pallets)::bigint    as dry_pallet_weeks,
    sum(w.liquid_pallets)::bigint as liquid_pallet_weeks,
    sum(w.other_pallets)::bigint  as other_pallet_weeks,
    jsonb_agg(
      jsonb_build_object(
        'date', w.monday,
        'pallets', w.dry_pallets + w.liquid_pallets + w.other_pallets,
        'dry', w.dry_pallets,
        'liquid', w.liquid_pallets,
        'other', w.other_pallets
      ) order by w.monday
    ) as week_breakdown,
    max(w.weekly_rate) as weekly_rate,
    max(w.dry_rate)    as dry_weekly_rate,
    max(w.liquid_rate) as liquid_weekly_rate,
    round(
      sum(w.dry_pallets)    * coalesce(max(w.dry_rate), 0)
      + sum(w.liquid_pallets) * coalesce(max(w.liquid_rate), 0)
      + sum(w.other_pallets)  * coalesce(max(w.weekly_rate), 0)
    , 2) as amount,
    round(sum(w.dry_pallets) * coalesce(max(w.dry_rate), 0), 2)       as dry_amount,
    round(sum(w.liquid_pallets) * coalesce(max(w.liquid_rate), 0), 2) as liquid_amount,
    round(sum(w.other_pallets) * coalesce(max(w.weekly_rate), 0), 2)  as other_amount
  from weekly w
  group by w.client_id;
$$;

revoke all on function public.pallet_billing_month(date) from public, anon;
grant execute on function public.pallet_billing_month(date) to authenticated;
