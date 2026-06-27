-- ============================================================
-- Pulse on Pulse — Meetings Hub: schema
--
-- Read-only mirror of the two Google Workspace meeting rooms,
-- with attendee-scoped agendas/notes/actions and a KPI tracker.
--
-- This migration creates the tables, indexes, unique constraints,
-- and the SECURITY DEFINER helper functions that the RLS policies
-- (see meetings_hub_rls.sql) depend on.
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

-- ── Tables ─────────────────────────────────────────────────

-- Standing-agenda templates (definitions; admin-managed).
create table if not exists public.meeting_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  description text,
  created_at  timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'meeting_templates_name_key') then
    alter table public.meeting_templates add constraint meeting_templates_name_key unique (name);
  end if;
end $$;

create table if not exists public.meeting_template_items (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.meeting_templates(id) on delete cascade,
  position     int not null default 0,
  topic        text not null,
  owner_role   text,
  time_box_min int
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'meeting_template_items_tpl_pos_key') then
    alter table public.meeting_template_items add constraint meeting_template_items_tpl_pos_key unique (template_id, position);
  end if;
end $$;

-- Meetings — one row per Google room booking. Written ONLY by the
-- meeting-rooms edge function (service role); see RLS migration.
create table if not exists public.meetings (
  id                  uuid primary key default gen_random_uuid(),
  google_event_id     text unique,
  google_recurring_id text,
  title               text,
  starts_at           timestamptz,
  ends_at             timestamptz,
  location            text,
  room_cal_id         text,
  status              text default 'confirmed',   -- confirmed | cancelled
  template_id         uuid,
  attendees_count     int default 0,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Attendees — populated from Google by the feed; drives access RLS.
-- Written ONLY by the edge function (service role).
create table if not exists public.meeting_attendees (
  id              uuid primary key default gen_random_uuid(),
  meeting_id      uuid not null references public.meetings(id) on delete cascade,
  email           text not null,
  display_name    text,
  user_id         uuid,
  response_status text,
  is_organizer    boolean default false,
  created_at      timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'meeting_attendees_meeting_email_key') then
    alter table public.meeting_attendees add constraint meeting_attendees_meeting_email_key unique (meeting_id, email);
  end if;
end $$;

-- Map a recurring series to a standing template (admin-managed).
create table if not exists public.meeting_series_templates (
  id                  uuid primary key default gen_random_uuid(),
  google_recurring_id text not null unique,
  template_id         uuid references public.meeting_templates(id) on delete set null,
  created_at          timestamptz not null default now()
);

-- Agenda items (attendee-scoped content).
create table if not exists public.meeting_agenda_items (
  id           uuid primary key default gen_random_uuid(),
  meeting_id   uuid not null references public.meetings(id) on delete cascade,
  position     int not null default 0,
  topic        text not null,
  owner_id     uuid,
  owner_role   text,
  time_box_min int,
  notes        text,
  done         boolean default false,
  carries_over boolean default false,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Action items (attendee-scoped content).
create table if not exists public.meeting_actions (
  id             uuid primary key default gen_random_uuid(),
  meeting_id     uuid not null references public.meetings(id) on delete cascade,
  agenda_item_id uuid references public.meeting_agenda_items(id) on delete set null,
  text           text not null,
  assigned_to    uuid,
  due_date       date,
  done           boolean default false,
  task_id        uuid,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- KPI definitions (admin-managed; readable by staff).
create table if not exists public.kpis (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  category       text,
  measures       text,
  unit           text,
  target         text,
  rag_rule       text,
  kpi_type       text default 'status',  -- numeric | status | cadence
  rag_thresholds jsonb,                  -- {"dir":"higher|lower","green":n,"amber":n}
  cadence        text,
  owner_role     text,
  owner_id       uuid,
  position       int default 0,
  active         boolean default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'kpis_name_key') then
    alter table public.kpis add constraint kpis_name_key unique (name);
  end if;
end $$;

-- KPI readings (attendee-scoped values; entered in meetings).
create table if not exists public.kpi_entries (
  id            uuid primary key default gen_random_uuid(),
  kpi_id        uuid not null references public.kpis(id) on delete cascade,
  period_start  date not null,
  value         text,
  numeric_value numeric,
  status        text,                    -- red | amber | green
  note          text,
  meeting_id    uuid references public.meetings(id) on delete set null,
  recorded_by   uuid,
  recorded_at   timestamptz not null default now()
);

-- Link a KPI set to a recurring series (admin-managed).
create table if not exists public.meeting_series_kpis (
  id                  uuid primary key default gen_random_uuid(),
  google_recurring_id text not null,
  kpi_id              uuid not null references public.kpis(id) on delete cascade,
  position            int default 0
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'meeting_series_kpis_recurring_kpi_key') then
    alter table public.meeting_series_kpis add constraint meeting_series_kpis_recurring_kpi_key unique (google_recurring_id, kpi_id);
  end if;
end $$;

-- ── Indexes (sized for RLS joins + latest-per-period) ──────
create index if not exists idx_meeting_attendees_email     on public.meeting_attendees(email);
create index if not exists idx_meeting_attendees_meeting   on public.meeting_attendees(meeting_id);
create index if not exists idx_meetings_starts_at          on public.meetings(starts_at);
create index if not exists idx_meetings_recurring          on public.meetings(google_recurring_id);
create index if not exists idx_agenda_meeting              on public.meeting_agenda_items(meeting_id);
create index if not exists idx_actions_meeting             on public.meeting_actions(meeting_id);
create index if not exists idx_kpi_entries_kpi_period      on public.kpi_entries(kpi_id, period_start);
create index if not exists idx_kpi_entries_meeting         on public.kpi_entries(meeting_id);
create index if not exists idx_series_kpis_recurring       on public.meeting_series_kpis(google_recurring_id);
create index if not exists idx_template_items_template     on public.meeting_template_items(template_id);

-- ── Helper functions (used by RLS) ─────────────────────────
-- Defined after the tables they reference (SQL function bodies are
-- validated at creation time).

-- Normalised current user email from the verified JWT.
create or replace function public.mh_current_email()
returns text
language sql
stable
set search_path = public
as $$
  select lower(trim(coalesce(auth.jwt() ->> 'email', '')))
$$;

-- True if the caller holds the meetings_admin override. Basis:
-- roles.is_pulse_admin (always) OR roles.permissions->>'meetings_admin' = 1.
-- SECURITY DEFINER so it can read app_users/roles regardless of their RLS.
create or replace function public.mh_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.app_users u
    join public.roles r on r.key = u.role
    where u.auth_user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and (
        r.is_pulse_admin is true
        or r.is_exec is true
        or coalesce(nullif(r.permissions ->> 'meetings_admin', '')::int, 0) = 1
      )
  )
$$;

-- True if the caller's email is an attendee of the given meeting.
-- SECURITY DEFINER to avoid RLS recursion on meeting_attendees.
create or replace function public.mh_is_attendee(m_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.meeting_attendees ma
    where ma.meeting_id = m_id
      and ma.email = public.mh_current_email()
  )
$$;
