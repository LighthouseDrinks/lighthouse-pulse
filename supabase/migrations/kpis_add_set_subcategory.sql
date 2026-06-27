-- Meetings Hub / KPIs: namespace the two KPI sets (management vs department)
-- and allow names to repeat across sets (e.g. "Stock Value" exists in both the
-- management Objectives set and the department Finance set).
-- Idempotent.

alter table public.kpis add column if not exists kpi_set text not null default 'department';
alter table public.kpis add column if not exists subcategory text;

-- Replace the global unique-on-name with a per-set/category unique so the two
-- sets can legitimately share KPI names without colliding.
alter table public.kpis drop constraint if exists kpis_name_key;
create unique index if not exists kpis_set_cat_name_key on public.kpis (kpi_set, category, name);
