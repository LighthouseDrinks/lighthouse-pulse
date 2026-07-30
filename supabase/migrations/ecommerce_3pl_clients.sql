-- ============================================================
-- Ecommerce — 3PL Clients
--
-- Backs the first tab of the new standalone "Ecommerce" section
-- in Pulse. Holds the third-party-logistics clients Lighthouse
-- fulfils for: the limited company that signed up, whether a
-- contract has been signed, the monthly retainer they pay, and
-- the margin they are on (free text).
--
-- Access model: all staff may read and write (is_staff() is the
-- NULL-safe helper defined in fix_is_staff_and_app_users_insert.sql).
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

-- ── Table ──────────────────────────────────────────────────
create table if not exists public.three_pl_clients (
  id                uuid primary key default gen_random_uuid(),
  company_name      text not null,          -- limited company that signed up
  contract_signed   boolean not null default false,
  monthly_retainer  numeric,                -- retaining fee per month
  margin            text,                   -- free text
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists idx_three_pl_clients_company on public.three_pl_clients(company_name);

-- ── Grants (RLS gates rows; grants gate the verb) ──────────
grant select, insert, update, delete on public.three_pl_clients to authenticated;
grant all on public.three_pl_clients to service_role;

-- ── Row-Level Security — staff read/write ──────────────────
alter table public.three_pl_clients enable row level security;

drop policy if exists three_pl_clients_select on public.three_pl_clients;
create policy three_pl_clients_select on public.three_pl_clients
  for select to authenticated
  using (public.is_staff());

drop policy if exists three_pl_clients_insert on public.three_pl_clients;
create policy three_pl_clients_insert on public.three_pl_clients
  for insert to authenticated
  with check (public.is_staff());

drop policy if exists three_pl_clients_update on public.three_pl_clients;
create policy three_pl_clients_update on public.three_pl_clients
  for update to authenticated
  using (public.is_staff())
  with check (public.is_staff());

drop policy if exists three_pl_clients_delete on public.three_pl_clients;
create policy three_pl_clients_delete on public.three_pl_clients
  for delete to authenticated
  using (public.is_staff());
