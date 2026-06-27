-- Named, reusable roster shift definitions, each with a baked-in break.
-- Picked from the roster "Manage shifts" library; the chosen name/times/break
-- are snapshotted onto roster_shifts when a shift is assigned.
create table if not exists public.shift_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  start_time time not null,
  end_time time not null,
  break_minutes int not null default 0,
  active boolean not null default true,
  created_at timestamptz default now(),
  created_by uuid
);

alter table public.shift_templates enable row level security;

-- Match the existing roster_shifts posture: open to authenticated users,
-- with write protection handled client-side via canEditRoster().
drop policy if exists shift_templates_authenticated_full_access on public.shift_templates;
create policy shift_templates_authenticated_full_access
  on public.shift_templates
  for all
  to authenticated
  using (true)
  with check (true);

-- Break (minutes) baked into each rostered shift, snapshotted from the template.
-- Subtracted from both rostered and actual hours in the attendance report.
alter table public.roster_shifts add column if not exists break_minutes int not null default 0;
