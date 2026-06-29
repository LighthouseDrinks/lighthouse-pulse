-- ============================================================
-- Meetings Hub: pull open actions across a recurring series group
--
-- Replaces the old "single immediately-previous meeting" client
-- logic. Aggregates ALL outstanding open actions from every
-- earlier meeting in the group (resolved via meeting_series_groups,
-- falling back to the meeting's own series), de-duplicates them by
-- text + assignee, inserts the survivors into the target meeting,
-- and supersedes the originals (carried_forward_at/to) so they
-- stop re-appearing and won't be pulled again.
--
-- SECURITY DEFINER so any attendee can roll actions forward across
-- sibling series they may not personally attend; access is still
-- gated to attendees/admins of the TARGET meeting, and tasks can
-- only be pulled into a current/upcoming occurrence (never backward
-- into a meeting that has already ended).
--
-- Idempotent: a second call finds the sources already carried and
-- the survivors already present, so it inserts nothing.
-- ============================================================

create or replace function public.meeting_pull_open_actions(p_meeting_id uuid)
returns setof public.meeting_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target  public.meetings;
  v_rec_ids text[];
  v_uid     uuid := auth.uid();
begin
  -- Access guard: caller must be an attendee or admin of the target.
  if not (public.mh_is_attendee(p_meeting_id) or public.mh_is_admin()) then
    raise exception 'Not authorised to pull actions into this meeting'
      using errcode = '42501';
  end if;

  select * into v_target from public.meetings where id = p_meeting_id;
  if not found then
    raise exception 'Meeting not found' using errcode = 'P0002';
  end if;

  if v_target.google_recurring_id is null then
    raise exception 'This is a one-off meeting - nothing to pull from'
      using errcode = '22023';
  end if;

  -- No backward pull: only current/upcoming occurrences may receive tasks.
  if coalesce(v_target.ends_at, v_target.starts_at) < now() then
    raise exception 'Cannot pull tasks into a meeting that has already ended'
      using errcode = '22023';
  end if;

  -- Resolve every series in the same group (fallback: this series only).
  select coalesce(array_agg(distinct g2.google_recurring_id), array[v_target.google_recurring_id])
    into v_rec_ids
  from public.meeting_series_groups g1
  join public.meeting_series_groups g2 on g2.group_id = g1.group_id
  where g1.google_recurring_id = v_target.google_recurring_id;

  if v_rec_ids is null or array_length(v_rec_ids, 1) is null then
    v_rec_ids := array[v_target.google_recurring_id];
  end if;

  -- Candidate open, not-yet-carried actions from EARLIER meetings in the group.
  -- An action linked to a completed job_task counts as done even if its own
  -- done flag is stale, so it is never carried forward.
  create temp table _cand on commit drop as
  select a.id,
         a.meeting_id,
         a.text,
         a.assigned_to,
         a.due_date,
         a.task_id,
         coalesce(a.carry_count, 0) as carry_count,
         a.created_at,
         lower(btrim(a.text)) || '|' || coalesce(a.assigned_to::text, '') as k
  from public.meeting_actions a
  join public.meetings m on m.id = a.meeting_id
  where m.google_recurring_id = any(v_rec_ids)
    and m.starts_at < v_target.starts_at
    and a.meeting_id <> p_meeting_id
    and a.done = false
    and a.carried_forward_at is null
    and not exists (
      select 1 from public.job_tasks jt
      where jt.id = a.task_id and jt.status = 'completed'
    );

  -- Keys already open on the target meeting (avoid duplicates).
  create temp table _existing on commit drop as
  select distinct lower(btrim(a.text)) || '|' || coalesce(a.assigned_to::text, '') as k
  from public.meeting_actions a
  where a.meeting_id = p_meeting_id
    and a.done = false;

  -- One representative per key (most recent), excluding keys already on target.
  create temp table _rep on commit drop as
  select distinct on (k) id, meeting_id, text, assigned_to, due_date, task_id, carry_count, k
  from _cand
  where k not in (select k from _existing)
  order by k, created_at desc;

  -- Insert the survivors into the target meeting, preserving the task link so a
  -- later task completion still flows back onto the carried action, and stamping
  -- where it came from plus how many times it has now been carried.
  create temp table _ins (id uuid) on commit drop;
  with ins as (
    insert into public.meeting_actions (id, meeting_id, text, assigned_to, due_date, task_id, created_by, carried_from_meeting_id, carry_count)
    select gen_random_uuid(), p_meeting_id, r.text, r.assigned_to, r.due_date, r.task_id, v_uid, r.meeting_id, r.carry_count + 1
    from _rep r
    returning id
  )
  insert into _ins select id from ins;

  -- Supersede every gathered source (including duplicates that collapsed into a
  -- survivor, and any whose key already lived on the target) so the only open
  -- copy of each task now lives on the target meeting.
  update public.meeting_actions a
     set carried_forward_at = now(),
         carried_forward_to = p_meeting_id,
         updated_at = now()
  where a.id in (select id from _cand);

  raise log 'meeting_pull_open_actions: meeting=% pulled=% superseded=%',
    p_meeting_id,
    (select count(*) from _ins),
    (select count(*) from _cand);

  return query
    select * from public.meeting_actions
    where id in (select id from _ins)
    order by created_at asc;
end;
$$;

grant execute on function public.meeting_pull_open_actions(uuid) to authenticated;
