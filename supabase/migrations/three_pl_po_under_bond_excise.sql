-- ============================================================
-- Ecommerce / 3PL — under-bond purchase orders
--
-- Builds on ecommerce_3pl_stores_and_po.sql and
-- three_pl_clients_under_bond_po.sql. When a client has
-- under_bond_po ticked, a generated PO strips the per-unit
-- excise duty off the (duty-paid) purchase price.
--
--   three_pl_purchase_orders.under_bond        — PO priced under bond
--   three_pl_purchase_order_lines.excise_per_unit — excise stripped per unit
--
-- Idempotent / guarded: safe to re-run.
-- ============================================================

alter table public.three_pl_purchase_orders
  add column if not exists under_bond boolean not null default false;

alter table public.three_pl_purchase_order_lines
  add column if not exists excise_per_unit numeric;
