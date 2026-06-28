-- ============================================================
-- Meetings Hub: action carry-forward support
--
-- Adds the columns that let an open action be "moved" from an
-- earlier meeting into a later one (so it stops re-appearing /
-- being re-pulled), and documents the prod-only
-- meeting_series_groups table in the repo for parity.
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

-- ── Carry-forward bookkeeping on actions ───────────────────
alter table public.meeting_actions
  add column if not exists carried_forward_at timestamptz;
alter table public.meeting_actions
  add column if not exists carried_forward_to uuid references public.meetings(id) on delete set null;

create index if not exists idx_actions_carried_forward
  on public.meeting_actions(carried_forward_to);

-- ── meeting_series_groups (parity with prod) ───────────────
-- Several distinct Google series (different google_recurring_id) can be tied
-- together as one logical meeting so open actions roll forward across the whole
-- group (e.g. Mon -> Wed -> Fri). One row per series; rows sharing a group_id
-- form one chain.
create table if not exists public.meeting_series_groups (
  google_recurring_id text primary key,
  group_id            uuid not null,
  group_name          text,
  created_at          timestamptz not null default now()
);
create index if not exists idx_series_groups_group
  on public.meeting_series_groups(group_id);

grant select, insert, update, delete on public.meeting_series_groups to authenticated;
grant all on public.meeting_series_groups to service_role;

alter table public.meeting_series_groups enable row level security;

drop policy if exists series_groups_select on public.meeting_series_groups;
create policy series_groups_select on public.meeting_series_groups
  for select to authenticated using (true);

drop policy if exists series_groups_write on public.meeting_series_groups;
create policy series_groups_write on public.meeting_series_groups
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());
