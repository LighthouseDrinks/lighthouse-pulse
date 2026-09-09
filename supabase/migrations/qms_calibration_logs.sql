-- QMS: calibration logs (Anton Paar water test first; more log_types later)
-- Rows are never deleted or updated. Idempotent: safe to re-run.

create table if not exists public.qms_calibration_logs (
  id uuid primary key default gen_random_uuid(),
  log_type text not null default 'anton_paar_water_test',
  device text not null default 'Anton Paar',
  check_date date not null,
  ref_temp_c numeric not null,
  ref_density numeric not null,
  ref_abv numeric not null,
  result text not null check (result in ('pass', 'fail')),
  standard_liquid text not null default 'Distilled Water',
  job_id text,
  recorded_by_id uuid,
  recorded_by_name text,
  recorded_by_email text,
  created_at timestamptz not null default now()
);

create index if not exists qms_calibration_logs_type_date
  on public.qms_calibration_logs (log_type, check_date desc);

alter table public.qms_calibration_logs enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_calibration_logs' and policyname='staff_select_qms_calibration_logs') then
    create policy staff_select_qms_calibration_logs on public.qms_calibration_logs
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_calibration_logs' and policyname='staff_insert_qms_calibration_logs') then
    create policy staff_insert_qms_calibration_logs on public.qms_calibration_logs
      for insert to authenticated with check (public.is_staff());
  end if;
end $$;

grant select, insert on public.qms_calibration_logs to authenticated;
