-- ============================================================
-- Meetings Hub: carry-over provenance on actions
--
-- Lets the UI separate tasks carried over from previous meetings
-- from tasks newly raised in the current meeting, and surface how
-- many times a task has been rolled forward (social pressure to
-- actually close things out).
--
--   carried_from_meeting_id  the earlier meeting a carried action
--                            came from (null = raised in this meeting)
--   carry_count              how many times this task has been
--                            carried forward (0 = never)
--
-- Idempotent: safe to re-run.
-- ============================================================

alter table public.meeting_actions
  add column if not exists carried_from_meeting_id uuid references public.meetings(id) on delete set null;
alter table public.meeting_actions
  add column if not exists carry_count int not null default 0;

create index if not exists idx_actions_carried_from
  on public.meeting_actions(carried_from_meeting_id);
