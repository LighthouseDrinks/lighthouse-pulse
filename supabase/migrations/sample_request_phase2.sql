-- Sample Request Flow — Phase 2 schema
-- Builds on sample_request_flow.sql. Adds request origin (internal vs external),
-- requester email, chargeable + cost capture fields, coordinator sign-off and a
-- "can't fulfil" response, plus a sample_brands table for our own brands so they
-- can be preloaded / quick-picked when requesting a sample.
--
-- Idempotent: safe to re-run. Applied manually via the Supabase dashboard
-- (SQL migrations are tracked in git for review; see .gitignore note).

-- ── samples: origin, requester, charging, sign-off ───────────────────────────
alter table public.samples add column if not exists request_source text;          -- 'internal' | 'external'
alter table public.samples add column if not exists requester_email text;          -- email of the person raising the request
alter table public.samples add column if not exists chargeable boolean not null default false;
alter table public.samples add column if not exists excise_duty numeric;            -- capture now, price later
alter table public.samples add column if not exists shipping_cost numeric;
alter table public.samples add column if not exists sample_cost numeric;
alter table public.samples add column if not exists signed_off_by text;             -- coordinator who signed the request off
alter table public.samples add column if not exists signed_off_at timestamptz;
alter table public.samples add column if not exists coordinator_response text;      -- message sent back when a request can't be fulfilled

-- Backfill origin for legacy rows: anything with a client_id/recipient came from
-- staff logging on behalf of someone; treat existing rows as internal so the new
-- chargeable prompt doesn't retroactively flip them.
update public.samples set request_source = 'internal' where request_source is null;

-- ── sample_brands: our own brands, preloaded for quick-pick ──────────────────
create table if not exists public.sample_brands (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  liquid_type  text,                                   -- Whiskey / Gin / Vodka / ...
  default_abv  numeric,                                -- pre-fills ABV on the component row
  notes        text,
  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists idx_sample_brands_active on public.sample_brands (is_active, sort_order);

-- Seed one of our own brands as a starting example. Staff add the rest in-app
-- via Samples → Manage Brands.
insert into public.sample_brands (name, liquid_type, default_abv, sort_order)
select 'O''Doherty''s Irish Whiskey', 'Whiskey', 40, 0
where not exists (
  select 1 from public.sample_brands where lower(name) = lower('O''Doherty''s Irish Whiskey')
);

-- ── RLS: staff manage brands; anon never touches the table directly ──────────
-- External submissions read/write through the sample-request edge function
-- (service role), so no anon grants are needed here.
alter table public.sample_brands enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies where schemaname='public'
       and tablename='sample_brands' and policyname='staff_all_sample_brands'
  ) then
    create policy "staff_all_sample_brands" on public.sample_brands
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
end
$$;
revoke insert, update, delete, truncate, references, trigger on public.sample_brands from anon;
revoke truncate, references, trigger on public.sample_brands from authenticated;
