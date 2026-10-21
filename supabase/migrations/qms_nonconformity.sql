-- QMS nonconformity log (3.01.03.02.04 report transcribed onto 3.01.03.01.06).
-- Reports are never deleted. Every insert and update is written to history.
-- Idempotent: safe to re-run.

create table if not exists public.qms_nonconformity (
  id uuid primary key default gen_random_uuid(),
  nc_no text not null unique,
  nc_date date,
  source_of_issue text,
  description text,
  manager_input text,
  origin text,
  correction text,
  root_cause text,
  planned_action text,
  action_by text,
  how_implemented text,
  within_days text,
  completed_on date,
  review_within text,
  review_date date,
  review_effectiveness text,
  review_by text,
  status text not null default 'open' check (status in ('open', 'closed')),
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  updated_by_id uuid,
  updated_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists qms_nonconformity_created
  on public.qms_nonconformity (created_at desc);

create index if not exists qms_nonconformity_status
  on public.qms_nonconformity (status, created_at desc);

-- First digital number is 047, following 046 on the paper log.
create sequence if not exists public.qms_nonconformity_seq start with 47;

create table if not exists public.qms_nonconformity_history (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.qms_nonconformity(id) on delete restrict,
  action text not null,
  actor_id uuid,
  actor_name text,
  actor_email text,
  snapshot jsonb,
  created_at timestamptz not null default now()
);

create index if not exists qms_nonconformity_history_report
  on public.qms_nonconformity_history (report_id, created_at desc);

create or replace function public.has_qms_log()
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
        r.is_exec is true
        or coalesce(nullif(r.permissions ->> 'qms_log', '')::int, 0) = 1
      )
  )
$$;

create or replace function public.qms_nonconformity_assign_no()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.nc_no is null or btrim(new.nc_no) = '' then
    new.nc_no := lpad(nextval('public.qms_nonconformity_seq')::text, 3, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists qms_nonconformity_assign_no on public.qms_nonconformity;
create trigger qms_nonconformity_assign_no
  before insert on public.qms_nonconformity
  for each row execute function public.qms_nonconformity_assign_no();

alter table public.qms_nonconformity enable row level security;
alter table public.qms_nonconformity_history enable row level security;

drop policy if exists staff_select_qms_nonconformity on public.qms_nonconformity;
drop policy if exists staff_insert_qms_nonconformity on public.qms_nonconformity;
drop policy if exists qms_log_update_qms_nonconformity on public.qms_nonconformity;
drop policy if exists staff_select_qms_nc_hist on public.qms_nonconformity_history;
drop policy if exists staff_insert_qms_nc_hist on public.qms_nonconformity_history;

create policy staff_select_qms_nonconformity on public.qms_nonconformity
  for select to authenticated using (public.is_staff());

create policy staff_insert_qms_nonconformity on public.qms_nonconformity
  for insert to authenticated with check (public.is_staff());

create policy qms_log_update_qms_nonconformity on public.qms_nonconformity
  for update to authenticated
  using (public.has_qms_log())
  with check (public.has_qms_log());

create policy staff_select_qms_nc_hist on public.qms_nonconformity_history
  for select to authenticated using (public.is_staff());

create policy staff_insert_qms_nc_hist on public.qms_nonconformity_history
  for insert to authenticated with check (public.is_staff());

grant select, insert, update on public.qms_nonconformity to authenticated;
grant select, insert on public.qms_nonconformity_history to authenticated;
grant usage, select on sequence public.qms_nonconformity_seq to authenticated;
grant execute on function public.has_qms_log() to authenticated;
