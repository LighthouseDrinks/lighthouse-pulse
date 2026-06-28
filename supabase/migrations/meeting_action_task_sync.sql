-- ============================================================
-- Meetings Hub: keep meeting_actions.done in sync with the
-- linked job_tasks status.
--
-- A meeting action can be "sent to tasks" (meeting_actions.task_id
-- -> job_tasks.id). Completing/reopening that task in the Tasks
-- module previously did NOT update the meeting action, so finished
-- work kept showing as an open action (and got carried forward into
-- later meetings). This trigger mirrors the task's completion state
-- onto every meeting action linked to it, regardless of which UI
-- path changed the task.
--
-- Idempotent: safe to re-run.
-- ============================================================

create or replace function public.sync_meeting_action_done_from_task()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    update public.meeting_actions
       set done = (new.status = 'completed'),
           updated_at = now()
     where task_id = new.id
       and done is distinct from (new.status = 'completed');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_meeting_action_done on public.job_tasks;
create trigger trg_sync_meeting_action_done
  after update on public.job_tasks
  for each row
  execute function public.sync_meeting_action_done_from_task();
