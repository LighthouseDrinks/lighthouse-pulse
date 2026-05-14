-- Make vessel_id nullable (history entries may relate to a container not yet linked to a vessel)
-- and add container_id so history can be queried from either side
alter table vessel_history alter column vessel_id drop not null;
alter table vessel_history add column if not exists container_id text;
create index if not exists vessel_history_container_id_idx on vessel_history (container_id);
