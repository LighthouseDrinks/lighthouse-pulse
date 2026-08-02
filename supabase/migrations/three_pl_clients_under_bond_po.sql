-- ============================================================
-- three_pl_clients: Under Bond PO flag
-- Adds a boolean surfaced as an inline checkbox on the
-- Ecommerce → 3PL Clients table:
--   under_bond_po — client's POs are priced under bond (excise
--                   stripped off the duty-paid purchase price)
-- Any staff user can toggle this (existing three_pl_clients_update RLS).
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

alter table public.three_pl_clients
  add column if not exists under_bond_po boolean not null default false;
