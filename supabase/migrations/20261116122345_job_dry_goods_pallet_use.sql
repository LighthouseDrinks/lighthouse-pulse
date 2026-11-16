-- Dry goods pallets taken out at supply-chain sign-off, and put back
-- on the job results tab. The difference is the dry goods pallets used,
-- written to the pallet ledger by pallet_capture_job().

alter table public.jobs
  add column if not exists pallets_removed_dry  int,
  add column if not exists pallets_returned_dry int;

alter table public.jobs
  drop constraint if exists jobs_pallets_removed_dry_chk;
alter table public.jobs
  add constraint jobs_pallets_removed_dry_chk
  check (pallets_removed_dry is null or pallets_removed_dry >= 1);

alter table public.jobs
  drop constraint if exists jobs_pallets_returned_dry_chk;
alter table public.jobs
  add constraint jobs_pallets_returned_dry_chk
  check (pallets_returned_dry is null or pallets_returned_dry >= 0);

alter table public.jobs
  drop constraint if exists jobs_pallets_dry_used_chk;
alter table public.jobs
  add constraint jobs_pallets_dry_used_chk
  check (
    pallets_returned_dry is null
    or pallets_removed_dry is null
    or pallets_returned_dry < pallets_removed_dry
  );

create or replace function public.pallet_capture_job()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_date date := coalesce(NEW.date_completed::date, current_date);
  v_ref  text := 'Job ' || NEW.id::text;
  v_note text;
begin
  delete from public.pallet_movements
   where source = 'job'
     and source_id in (NEW.id::text, NEW.id::text || ':dry', NEW.id::text || ':liquid');

  if NEW.client_id is null then
    return NEW;
  end if;

  if NEW.pallets_used_dry is not null or NEW.pallets_used_liquid is not null then
    if coalesce(NEW.pallets_used_dry, 0) > 0 then
      -- Only the pallets actually used are recorded. Removed and returned
      -- stay on the job so the difference can be recalculated; they are
      -- not separate storage movements.
      v_note := NEW.pallets_used_dry::text || ' dry goods pallets used for ' || NEW.id::text;
      insert into public.pallet_movements
        (client_id, movement_type, quantity, movement_date, reference, notes, source, source_id, pallet_kind, job_id, performed_by)
      values
        (NEW.client_id, 'used', -NEW.pallets_used_dry, v_date, v_ref, v_note,
         'job', NEW.id::text || ':dry', 'dry', NEW.id::text, NEW.results_signed_by);
    end if;
    if coalesce(NEW.pallets_used_liquid, 0) > 0 then
      insert into public.pallet_movements
        (client_id, movement_type, quantity, movement_date, reference, notes, source, source_id, pallet_kind, job_id, performed_by)
      values
        (NEW.client_id, 'used', -NEW.pallets_used_liquid, v_date, v_ref,
         NEW.pallets_used_liquid::text || ' liquid pallets used for ' || NEW.id::text,
         'job', NEW.id::text || ':liquid', 'liquid', NEW.id::text, NEW.results_signed_by);
    end if;
  elsif NEW.pallets_used is not null and NEW.pallets_used > 0 then
    insert into public.pallet_movements
      (client_id, movement_type, quantity, movement_date, reference, source, source_id, job_id)
    values
      (NEW.client_id, 'used', -NEW.pallets_used, v_date, v_ref, 'job', NEW.id::text, NEW.id::text);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_pallet_capture_job on public.jobs;
create trigger trg_pallet_capture_job
  after insert or update of pallets_used, pallets_used_dry, pallets_used_liquid
  on public.jobs
  for each row execute function public.pallet_capture_job();

revoke all on function public.pallet_capture_job() from public, anon, authenticated;
