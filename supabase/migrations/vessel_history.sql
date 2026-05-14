-- Vessel history log: stores timestamped notes for each vessel (e.g. decommissioning reason, reactivation)
create table if not exists vessel_history (
  id          bigserial primary key,
  vessel_id   text        not null,
  note        text        not null,
  created_by  text,
  created_at  timestamptz not null default now()
);

create index if not exists vessel_history_vessel_id_created_at_idx
  on vessel_history (vessel_id, created_at desc);
