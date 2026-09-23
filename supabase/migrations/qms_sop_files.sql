-- QMS SOP source files (PDF / Word). The file is the controlled copy.
-- Staff can read and add objects. No update and no delete, so a published
-- file cannot be overwritten. A replacement is a new object.
-- Idempotent: safe to re-run.

alter table public.qms_document_revisions
  add column if not exists source_path text,
  add column if not exists source_name text,
  add column if not exists source_mime text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'qms-sop-files',
  'qms-sop-files',
  false,
  26214400,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists qms_sop_files_staff_select on storage.objects;
drop policy if exists qms_sop_files_staff_insert on storage.objects;

create policy qms_sop_files_staff_select on storage.objects
  for select to authenticated
  using (bucket_id = 'qms-sop-files' and public.is_staff());

create policy qms_sop_files_staff_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'qms-sop-files' and public.is_staff());
