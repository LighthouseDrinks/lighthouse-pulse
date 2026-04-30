-- ─────────────────────────────────────────────────────────────────────────────
-- Plant Display — DB changes
-- Run this in the Supabase SQL editor (project dashboard → SQL Editor)
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Actual start / end timestamps on jobs
--    actual_start  — stamped when planner presses "Start Job"
--    actual_end    — stamped when planner presses "End Job"
alter table jobs
  add column if not exists actual_start timestamptz,
  add column if not exists actual_end   timestamptz;

-- 2. Bottle-count events from Shelly sensors
create table if not exists line_events (
  id         uuid        primary key default gen_random_uuid(),
  line_id    text        not null,          -- matches job_bay cast to text, e.g. '1'
  job_id     text        references jobs(id) on delete set null,
  count      int         not null default 1,
  created_at timestamptz not null default now()
);

-- Index for fast per-job and per-line queries
create index if not exists line_events_job_id_idx     on line_events(job_id);
create index if not exists line_events_line_id_idx    on line_events(line_id);
create index if not exists line_events_created_at_idx on line_events(created_at);

-- RLS
alter table line_events enable row level security;

-- Authenticated users can read (plant display, reports, etc.)
do $$ begin
  if not exists (
    select 1 from pg_policies where tablename = 'line_events' and policyname = 'line_events_read'
  ) then
    execute 'create policy "line_events_read" on line_events for select to authenticated using (true)';
  end if;
end $$;

-- Service role (edge function) can insert — anon cannot
do $$ begin
  if not exists (
    select 1 from pg_policies where tablename = 'line_events' and policyname = 'line_events_insert'
  ) then
    execute 'create policy "line_events_insert" on line_events for insert to service_role with check (true)';
  end if;
end $$;

-- Enable Realtime so the plant page can subscribe
alter publication supabase_realtime add table line_events;

-- 3. Live throughput view — bottles per hour over the last 10 minutes
--    (sum of count in last 10 min × 6 ≈ extrapolated hourly rate)
create or replace view line_throughput_live as
select
  line_id,
  sum(count) * 6                            as bottles_per_hour,
  max(created_at)                           as last_event_at
from line_events
where created_at > now() - interval '10 minutes'
group by line_id;
