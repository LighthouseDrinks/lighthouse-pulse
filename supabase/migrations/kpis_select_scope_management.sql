-- Scope KPI definition visibility.
-- Department KPI definitions remain readable by all authenticated staff.
-- Management ("Lighthouse Objectives") KPI definitions are readable only by
-- meetings admins, or by attendees of a meeting whose series reviews that KPI
-- (so non-admin attendees of the management meeting still see them in-meeting).
-- KPI *values* (kpi_entries) remain attendee/admin-scoped, unchanged.

drop policy if exists kpis_select on public.kpis;
create policy kpis_select on public.kpis
  for select to authenticated
  using (
    kpi_set <> 'management'
    or public.mh_is_admin()
    or exists (
      select 1
      from public.meeting_series_kpis sk
      join public.meetings m on m.google_recurring_id = sk.google_recurring_id
      where sk.kpi_id = kpis.id
        and public.mh_is_attendee(m.id)
    )
  );
