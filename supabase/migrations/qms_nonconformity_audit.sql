-- Nonconformity review fields: due dates, severity, BRC clause, a linked
-- record, and files kept with the report. Nothing is deleted.
-- Idempotent: safe to re-run.

alter table public.qms_nonconformity
  add column if not exists due_on date,
  add column if not exists review_due_on date,
  add column if not exists severity text,
  add column if not exists brc_clause text,
  add column if not exists link_kind text,
  add column if not exists link_id uuid,
  add column if not exists link_label text;

alter table public.qms_nonconformity
  drop constraint if exists qms_nonconformity_severity_check;
alter table public.qms_nonconformity
  add constraint qms_nonconformity_severity_check
  check (severity is null or severity in ('low', 'medium', 'high', 'food_safety'));

alter table public.qms_nonconformity
  drop constraint if exists qms_nonconformity_link_kind_check;
alter table public.qms_nonconformity
  add constraint qms_nonconformity_link_kind_check
  check (link_kind is null or link_kind in ('complaint', 'supplier', 'job', 'glass'));

create table if not exists public.qms_nonconformity_files (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.qms_nonconformity(id) on delete restrict,
  storage_path text not null,
  file_name text not null,
  mime text,
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  created_at timestamptz not null default now()
);

create index if not exists qms_nonconformity_files_report_idx
  on public.qms_nonconformity_files (report_id, created_at);

alter table public.qms_nonconformity_files enable row level security;

drop policy if exists staff_select_qms_nc_files on public.qms_nonconformity_files;
drop policy if exists staff_insert_qms_nc_files on public.qms_nonconformity_files;

create policy staff_select_qms_nc_files on public.qms_nonconformity_files
  for select to authenticated using (public.is_staff());

create policy staff_insert_qms_nc_files on public.qms_nonconformity_files
  for insert to authenticated with check (public.is_staff());

grant select, insert on public.qms_nonconformity_files to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'qms-nc-files',
  'qms-nc-files',
  false,
  26214400,
  array[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists qms_nc_files_staff_select on storage.objects;
drop policy if exists qms_nc_files_staff_insert on storage.objects;

create policy qms_nc_files_staff_select on storage.objects
  for select to authenticated
  using (bucket_id = 'qms-nc-files' and public.is_staff());

create policy qms_nc_files_staff_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'qms-nc-files' and public.is_staff());
