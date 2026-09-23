-- QMS: external contractor calibration register.
-- Equipment the business sends out for calibration, plus each certificate.
-- Reminders are sent by the qms-calibration-reminders edge function.
-- Idempotent: safe to re-run.

create table if not exists public.qms_external_equipment (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  serial_no text,
  location text,
  contractor text,
  notes text,
  sort_order integer not null default 0,
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists qms_external_equipment_name_serial
  on public.qms_external_equipment (name, coalesce(serial_no, ''));

create table if not exists public.qms_external_calibrations (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.qms_external_equipment(id) on delete cascade,
  calibrated_on date,
  next_due_on date,
  cert_path text,
  cert_name text,
  cert_mime text,
  notes text,
  recorded_by_id uuid,
  recorded_by_name text,
  recorded_by_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (calibrated_on is not null or next_due_on is not null)
);

create index if not exists qms_external_calibrations_equip
  on public.qms_external_calibrations (equipment_id, created_at desc);

create table if not exists public.qms_external_reminder_log (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.qms_external_equipment(id) on delete cascade,
  due_on date not null,
  kind text not null check (kind in ('d30', 'd14', 'd7', 'overdue')),
  sent_on date not null,
  created_at timestamptz not null default now()
);

create unique index if not exists qms_external_reminder_log_band
  on public.qms_external_reminder_log (equipment_id, due_on, kind)
  where kind <> 'overdue';

create unique index if not exists qms_external_reminder_log_overdue_day
  on public.qms_external_reminder_log (equipment_id, due_on, sent_on)
  where kind = 'overdue';

alter table public.qms_external_equipment enable row level security;
alter table public.qms_external_calibrations enable row level security;
alter table public.qms_external_reminder_log enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_equipment' and policyname = 'staff_select_qms_ext_equip') then
    create policy staff_select_qms_ext_equip on public.qms_external_equipment
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_equipment' and policyname = 'staff_insert_qms_ext_equip') then
    create policy staff_insert_qms_ext_equip on public.qms_external_equipment
      for insert to authenticated with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_equipment' and policyname = 'staff_update_qms_ext_equip') then
    create policy staff_update_qms_ext_equip on public.qms_external_equipment
      for update to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_equipment' and policyname = 'staff_delete_qms_ext_equip') then
    create policy staff_delete_qms_ext_equip on public.qms_external_equipment
      for delete to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_calibrations' and policyname = 'staff_select_qms_ext_cal') then
    create policy staff_select_qms_ext_cal on public.qms_external_calibrations
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_calibrations' and policyname = 'staff_insert_qms_ext_cal') then
    create policy staff_insert_qms_ext_cal on public.qms_external_calibrations
      for insert to authenticated with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_calibrations' and policyname = 'staff_update_qms_ext_cal') then
    create policy staff_update_qms_ext_cal on public.qms_external_calibrations
      for update to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'qms_external_calibrations' and policyname = 'staff_delete_qms_ext_cal') then
    create policy staff_delete_qms_ext_cal on public.qms_external_calibrations
      for delete to authenticated using (public.is_staff());
  end if;
end $$;

grant select, insert, update, delete on public.qms_external_equipment to authenticated;
grant select, insert, update, delete on public.qms_external_calibrations to authenticated;

-- Reminder log is written only by the edge function (service role bypasses RLS).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'qms-calibration-certs',
  'qms-calibration-certs',
  false,
  26214400,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists qms_cal_certs_staff_select on storage.objects;
drop policy if exists qms_cal_certs_staff_insert on storage.objects;
drop policy if exists qms_cal_certs_staff_update on storage.objects;
drop policy if exists qms_cal_certs_staff_delete on storage.objects;

create policy qms_cal_certs_staff_select on storage.objects
  for select to authenticated
  using (bucket_id = 'qms-calibration-certs' and public.is_staff());

create policy qms_cal_certs_staff_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'qms-calibration-certs' and public.is_staff());

create policy qms_cal_certs_staff_update on storage.objects
  for update to authenticated
  using (bucket_id = 'qms-calibration-certs' and public.is_staff())
  with check (bucket_id = 'qms-calibration-certs' and public.is_staff());

create policy qms_cal_certs_staff_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'qms-calibration-certs' and public.is_staff());

-- Cron authenticates with a secret that never leaves the database.
-- supabase_vault is already installed in the vault schema.

create or replace function public.qms_cal_cron_secret_matches(secret text)
returns boolean
language sql
security definer
set search_path = vault, public
as $$
  select coalesce(secret, '') <> ''
    and exists (
      select 1
      from vault.decrypted_secrets
      where name = 'qms_cal_cron_secret'
        and decrypted_secret = secret
    );
$$;

revoke all on function public.qms_cal_cron_secret_matches(text) from public;
revoke all on function public.qms_cal_cron_secret_matches(text) from anon, authenticated;
grant execute on function public.qms_cal_cron_secret_matches(text) to service_role;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'qms_cal_cron_secret') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'qms_cal_cron_secret',
      'Bearer check for the external calibration reminder job'
    );
  end if;
end $$;

-- The SQL matcher above cannot decrypt Vault when it runs as the migration role.
-- The edge function compares a SHA-256 hash instead. Authenticated users
-- have no access to this row.
create table if not exists public.qms_cal_cron_check (
  id integer primary key,
  secret_hash text not null
);
alter table public.qms_cal_cron_check enable row level security;
revoke all on public.qms_cal_cron_check from public, anon, authenticated;
grant select on public.qms_cal_cron_check to service_role;

insert into public.qms_cal_cron_check (id, secret_hash)
select 1, encode(extensions.digest(decrypted_secret, 'sha256'), 'hex')
from vault.decrypted_secrets
where name = 'qms_cal_cron_secret'
on conflict (id) do update set secret_hash = excluded.secret_hash;

-- Seed from ISO schedule 3.01.03.01.14 v002.
-- Future dates (as of 23 Sep 2026) are next due. Past dates are the last
-- certificate on file, with next due left blank so they do not email.

insert into public.qms_external_equipment (name, serial_no, sort_order)
values
  ('Anton Paar', '84697042', 10),
  ('Scales', 'AIP1230009', 20),
  ('Photo spec.', null, 30),
  ('Tank 1', null, 40),
  ('Tank 2', null, 50),
  ('Tank 3', null, 60),
  ('Reach Truck', null, 70),
  ('Forklift, on lease from CBW', null, 80),
  ('Forklift, owned', null, 90),
  ('Chiller', null, 100),
  ('JCB Generator', null, 110)
on conflict do nothing;

insert into public.qms_external_calibrations (equipment_id, calibrated_on, next_due_on, notes, recorded_by_name)
select e.id, v.calibrated_on, v.next_due_on, 'Imported from ISO schedule 3.01.03.01.14 v002', 'ISO schedule import'
from (
  values
    ('Anton Paar'::text, '84697042'::text, date '2026-06-01', null::date),
    ('Scales', 'AIP1230009', null, date '2026-10-07'),
    ('Photo spec.', '', null, date '2026-10-07'),
    ('Tank 1', '', null, date '2026-10-01'),
    ('Tank 2', '', null, date '2026-10-01'),
    ('Tank 3', '', null, date '2026-10-01'),
    ('Reach Truck', '', date '2025-05-12', null),
    ('Forklift, on lease from CBW', '', date '2025-11-19', null)
) as v(name, serial_no, calibrated_on, next_due_on)
join public.qms_external_equipment e
  on e.name = v.name
 and coalesce(e.serial_no, '') = v.serial_no
where not exists (
  select 1 from public.qms_external_calibrations c where c.equipment_id = e.id
);
