-- ============================================================
-- three_pl_clients: Fulfild setup tracking
-- Adds two boolean flags surfaced as inline checkboxes on the
-- Ecommerce → 3PL Clients table:
--   fulfild_setup    — store set up on Fulfild
--   fulfild_cs_setup — customer service set up on Fulfild
-- Any staff user can toggle these (existing three_pl_clients_update RLS).
-- ============================================================

alter table public.three_pl_clients
  add column if not exists fulfild_setup    boolean not null default false,
  add column if not exists fulfild_cs_setup boolean not null default false;
