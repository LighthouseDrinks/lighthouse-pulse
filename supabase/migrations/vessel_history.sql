-- Vessel history log: stores timestamped notes for each vessel (e.g. archiving reason, reactivation)
create table if not exists vessel_history (
  id          bigserial primary key,
  vessel_id   text        not null,
  note        text        not null,
  created_by  text,
  created_at  timestamptz not null default now()
);

create index if not exists vessel_history_vessel_id_created_at_idx
  on vessel_history (vessel_id, created_at desc);

-- RLS: authenticated users have full access
alter table vessel_history enable row level security;

create policy "vessel_history_auth_all"
  on vessel_history for all
  to authenticated
  using (true)
  with check (true);

create policy "vessel_history_anon_select"
  on vessel_history for select
  to anon
  using (true);
