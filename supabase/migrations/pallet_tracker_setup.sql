-- ============================================================
-- Pallet Tracker
--
-- Operational tracking of client pallets stored at Lighthouse.
-- A running ledger per client:
--   current pallets = opening balance + Σ(signed movements)
-- Whole pallets only.
--
-- Capture points (frontend sets a count on the source record; the
-- triggers below write the ledger row atomically & idempotently):
--   * dry_goods_batches.pallet_count  -> pallet_in   (delivery)
--   * liquid_containers.pallet_count  -> pallet_in   (intake)
--   * jobs.pallets_used               -> used        (job close)
--   * manual pallet_out / adjustment  -> inserted by the app
--
-- Billing: monthly, based on a weekly (Monday) snapshot of pallets
-- held, summed into pallet-weeks × the client's weekly rate. Derived
-- from the ledger by pallet_billing_month(); locked into
-- pallet_billing_periods when the bookkeeper marks a month invoiced.
--
-- Access model: staff read/write (public.is_staff(), the NULL-safe
-- helper from fix_is_staff_and_app_users_insert.sql).
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

-- ── Source columns on existing tables (source of truth for capture) ──
alter table public.dry_goods_batches add column if not exists pallet_count int;
alter table public.liquid_containers add column if not exists pallet_count int;
alter table public.jobs             add column if not exists pallets_used int;

-- ── pallet_accounts: one row per client we store pallets for ─────────
create table if not exists public.pallet_accounts (
  client_id       text primary key,                       -- -> clients.id
  opening_pallets int  not null default 0,
  opening_date    date not null default date '2026-08-01',
  weekly_rate     numeric,                                 -- per pallet, per week
  notes           text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ── pallet_movements: the immutable ledger ──────────────────────────
create table if not exists public.pallet_movements (
  id            uuid primary key default gen_random_uuid(),
  client_id     text not null,
  movement_type text not null check (movement_type in ('pallet_in','pallet_out','used','adjustment')),
  quantity      int  not null,                             -- SIGNED delta on balance (in +, out/used -, adjust ±)
  movement_date date not null default current_date,        -- source EVENT date (not created_at)
  reference     text,
  notes         text,
  source        text not null default 'manual' check (source in ('dry_goods_batch','liquid_container','job','manual')),
  source_id     text,                                      -- originating record id (for auto-capture)
  job_id        text,
  performed_by  text,
  created_at    timestamptz not null default now()
);

-- One captured movement per source record -> idempotent upsert target.
create unique index if not exists uq_pallet_movements_source
  on public.pallet_movements (source, source_id)
  where source <> 'manual';
create index if not exists idx_pallet_movements_client on public.pallet_movements (client_id);
create index if not exists idx_pallet_movements_date   on public.pallet_movements (movement_date);

-- ── pallet_billing_periods: locked monthly invoices ────────────────
create table if not exists public.pallet_billing_periods (
  id             uuid primary key default gen_random_uuid(),
  client_id      text not null,
  period_start   date not null,                            -- first day of the billed month
  period_end     date not null,
  weeks_count    int  not null,                            -- Mondays in the month (4 or 5)
  pallet_weeks   int  not null,                            -- Σ of each Monday's pallet count
  week_breakdown jsonb,                                    -- [{date, pallets}] per Monday
  weekly_rate    numeric,                                  -- rate snapshot at billing time
  amount         numeric,                                  -- pallet_weeks × weekly_rate
  status         text not null default 'invoiced' check (status in ('to_invoice','invoiced')),
  invoiced_at    timestamptz,
  invoiced_by    text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (client_id, period_start)
);

-- ── Auto-create an account on first captured movement ───────────────
create or replace function public.pallet_ensure_account()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.pallet_accounts (client_id)
  values (NEW.client_id)
  on conflict (client_id) do nothing;
  return NEW;
end;
$$;

drop trigger if exists trg_pallet_ensure_account on public.pallet_movements;
create trigger trg_pallet_ensure_account
  before insert on public.pallet_movements
  for each row when (NEW.client_id is not null)
  execute function public.pallet_ensure_account();

-- Trigger functions must never be callable directly via the REST API.
-- Triggers still fire (they run in the table-owner context) regardless.
revoke all on function public.pallet_ensure_account() from public, anon, authenticated;

-- ── Capture: dry goods delivery -> pallet_in ────────────────────────
create or replace function public.pallet_capture_batch()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if NEW.pallet_count is not null and NEW.pallet_count > 0 and NEW.client_id is not null then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, performed_by)
    values
      (NEW.client_id, 'pallet_in', NEW.pallet_count, coalesce(NEW.delivery_date, current_date),
       coalesce(NEW.po_reference, NEW.batch_ref, left(NEW.id::text, 8)),
       'dry_goods_batch', NEW.id::text, NEW.received_by)
    on conflict (source, source_id) where source <> 'manual'
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

drop trigger if exists trg_pallet_capture_batch on public.dry_goods_batches;
create trigger trg_pallet_capture_batch
  after insert or update of pallet_count on public.dry_goods_batches
  for each row execute function public.pallet_capture_batch();
revoke all on function public.pallet_capture_batch() from public, anon, authenticated;

-- ── Capture: liquid intake -> pallet_in ─────────────────────────────
create or replace function public.pallet_capture_container()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if NEW.pallet_count is not null and NEW.pallet_count > 0 and NEW.client_id is not null then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id)
    values
      (NEW.client_id, 'pallet_in', NEW.pallet_count, current_date,
       NEW.reference, 'liquid_container', NEW.id::text)
    on conflict (source, source_id) where source <> 'manual'
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

drop trigger if exists trg_pallet_capture_container on public.liquid_containers;
create trigger trg_pallet_capture_container
  after insert or update of pallet_count on public.liquid_containers
  for each row execute function public.pallet_capture_container();
revoke all on function public.pallet_capture_container() from public, anon, authenticated;

-- ── Capture: job close -> used ──────────────────────────────────────
create or replace function public.pallet_capture_job()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if NEW.pallets_used is not null and NEW.pallets_used > 0 and NEW.client_id is not null then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, job_id)
    values
      (NEW.client_id, 'used', -NEW.pallets_used, coalesce(NEW.date_completed::date, current_date),
       'Job ' || NEW.id::text, 'job', NEW.id::text, NEW.id::text)
    on conflict (source, source_id) where source <> 'manual'
    do update set quantity      = excluded.quantity,
                  movement_date = excluded.movement_date,
                  client_id     = excluded.client_id;
  else
    delete from public.pallet_movements
     where source = 'job' and source_id = NEW.id::text;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_pallet_capture_job on public.jobs;
create trigger trg_pallet_capture_job
  after insert or update of pallets_used on public.jobs
  for each row execute function public.pallet_capture_job();
revoke all on function public.pallet_capture_job() from public, anon, authenticated;

-- ── Balances view (security_invoker so RLS of base tables applies) ──
drop view if exists public.pallet_balances;
create view public.pallet_balances
  with (security_invoker = on) as
select
  a.client_id,
  a.opening_pallets,
  a.opening_date,
  a.weekly_rate,
  a.is_active,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'pallet_in'), 0)   as total_in,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'pallet_out'), 0) as total_out,
  coalesce(-sum(m.quantity) filter (where m.movement_type = 'used'), 0)       as total_used,
  coalesce(sum(m.quantity) filter (where m.movement_type = 'adjustment'), 0)  as total_adjust,
  a.opening_pallets + coalesce(sum(m.quantity), 0)                            as current_pallets,
  max(m.movement_date)                                                        as last_movement_date
from public.pallet_accounts a
left join public.pallet_movements m on m.client_id = a.client_id
group by a.client_id, a.opening_pallets, a.opening_date, a.weekly_rate, a.is_active;

-- ── Monthly billing: weekly (Monday) snapshots -> pallet-weeks ──────
create or replace function public.pallet_billing_month(period_start date)
returns table (
  client_id      text,
  weeks_count    int,
  pallet_weeks   bigint,
  week_breakdown jsonb,
  weekly_rate    numeric,
  amount         numeric
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
    select a.client_id, a.opening_pallets, a.weekly_rate
    from public.pallet_accounts a
    where a.is_active
  ),
  weekly as (
    select ac.client_id, ac.weekly_rate, mo.monday,
           greatest(
             ac.opening_pallets + coalesce((
               select sum(m.quantity) from public.pallet_movements m
               where m.client_id = ac.client_id and m.movement_date <= mo.monday
             ), 0),
             0
           ) as pallets
    from acct ac cross join mondays mo
  )
  select
    w.client_id,
    count(*)::int                                                                as weeks_count,
    sum(w.pallets)::bigint                                                       as pallet_weeks,
    jsonb_agg(jsonb_build_object('date', w.monday, 'pallets', w.pallets) order by w.monday) as week_breakdown,
    max(w.weekly_rate)                                                           as weekly_rate,
    round(sum(w.pallets) * coalesce(max(w.weekly_rate), 0), 2)                   as amount
  from weekly w
  group by w.client_id;
$$;

-- ── Grants (RLS gates rows; grants gate the verb) ──────────────────
grant select, insert, update, delete on public.pallet_accounts        to authenticated;
grant select, insert, update, delete on public.pallet_movements       to authenticated;
grant select, insert, update, delete on public.pallet_billing_periods to authenticated;
grant select on public.pallet_balances to authenticated;
grant execute on function public.pallet_billing_month(date) to authenticated;
grant all on public.pallet_accounts        to service_role;
grant all on public.pallet_movements       to service_role;
grant all on public.pallet_billing_periods to service_role;

-- ── Row-Level Security — staff read/write ──────────────────────────
alter table public.pallet_accounts        enable row level security;
alter table public.pallet_movements        enable row level security;
alter table public.pallet_billing_periods  enable row level security;

drop policy if exists pallet_accounts_all on public.pallet_accounts;
create policy pallet_accounts_all on public.pallet_accounts
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists pallet_movements_all on public.pallet_movements;
create policy pallet_movements_all on public.pallet_movements
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists pallet_billing_periods_all on public.pallet_billing_periods;
create policy pallet_billing_periods_all on public.pallet_billing_periods
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- ── Permission key ─────────────────────────────────────────────────
-- Add pallets_edit to the roles matrix. Warehouse / stock roles that can
-- already edit dry goods get it by default; the bookkeeper (financial
-- controller) gets it for the Pallet Billing tab. Execs always bypass.
update public.roles
   set permissions = jsonb_set(coalesce(permissions, '{}'::jsonb), '{pallets_edit}',
                               coalesce(permissions->'drygoods_edit', 'false'::jsonb), true)
 where permissions ? 'drygoods_edit';
update public.roles
   set permissions = jsonb_set(coalesce(permissions, '{}'::jsonb), '{pallets_edit}', 'true'::jsonb, true)
 where key = 'financial_controller';
