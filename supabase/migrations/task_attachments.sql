-- Task attachments: file uploads on CRM tasks.
-- Adds a jsonb column on job_tasks (array of {name,url,path}) and a public
-- storage bucket mirroring the policies of the other upload buckets.

alter table public.job_tasks add column if not exists attachments jsonb;

insert into storage.buckets (id, name, public)
values ('task-attachments', 'task-attachments', true)
on conflict (id) do nothing;

create policy "task_attachments_auth_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'task-attachments');

create policy "task_attachments_public_read" on storage.objects
  for select
  using (bucket_id = 'task-attachments');

create policy "task_attachments_auth_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'task-attachments');
