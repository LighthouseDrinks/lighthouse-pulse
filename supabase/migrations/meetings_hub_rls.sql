-- ============================================================
-- Pulse on Pulse — Meetings Hub: Row-Level Security
--
-- This is the codebase's first genuinely-enforced (non-permissive)
-- RLS. Access model:
--   * meetings / meeting_attendees  → SELECT for attendees (or admin);
--                                     NO client writes (service-role only,
--                                     via the meeting-rooms edge function).
--                                     This is the anti-privilege-escalation
--                                     linchpin — a user cannot insert a row
--                                     making themselves an attendee.
--   * agenda / actions / kpi_entries→ full CRUD for attendees of the parent
--                                     meeting (or admin).
--   * definitions (kpis, templates, → SELECT for all staff; writes admin-only.
--     series maps)
--
-- "admin" = mh_is_admin() (is_pulse_admin OR permissions.meetings_admin).
-- "attendee" = mh_is_attendee(meeting_id) (JWT email in meeting_attendees).
--
-- Idempotent: drops policies before re-creating.
-- ============================================================

-- ── Grants (RLS gates rows; grants gate the verb) ──────────
grant select on public.meetings, public.meeting_attendees to authenticated;
grant select, insert, update, delete
  on public.meeting_agenda_items, public.meeting_actions, public.kpi_entries
  to authenticated;
grant select on public.kpis, public.meeting_templates, public.meeting_template_items,
  public.meeting_series_templates, public.meeting_series_kpis to authenticated;
grant insert, update, delete on public.kpis, public.meeting_templates,
  public.meeting_template_items, public.meeting_series_templates,
  public.meeting_series_kpis to authenticated;

grant all on public.meetings, public.meeting_attendees, public.meeting_agenda_items,
  public.meeting_actions, public.kpis, public.kpi_entries, public.meeting_templates,
  public.meeting_template_items, public.meeting_series_templates,
  public.meeting_series_kpis to service_role;

-- ── Enable RLS ─────────────────────────────────────────────
alter table public.meetings               enable row level security;
alter table public.meeting_attendees      enable row level security;
alter table public.meeting_agenda_items   enable row level security;
alter table public.meeting_actions        enable row level security;
alter table public.kpis                   enable row level security;
alter table public.kpi_entries            enable row level security;
alter table public.meeting_templates      enable row level security;
alter table public.meeting_template_items enable row level security;
alter table public.meeting_series_templates enable row level security;
alter table public.meeting_series_kpis    enable row level security;

-- ── meetings: attendee/admin read; no client writes ───────
drop policy if exists meetings_select on public.meetings;
create policy meetings_select on public.meetings
  for select to authenticated
  using (public.mh_is_attendee(id) or public.mh_is_admin());

-- ── meeting_attendees: attendee/admin read; no client writes
drop policy if exists meeting_attendees_select on public.meeting_attendees;
create policy meeting_attendees_select on public.meeting_attendees
  for select to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin());

-- ── meeting_agenda_items: attendee/admin full CRUD ─────────
drop policy if exists agenda_select on public.meeting_agenda_items;
create policy agenda_select on public.meeting_agenda_items
  for select to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists agenda_insert on public.meeting_agenda_items;
create policy agenda_insert on public.meeting_agenda_items
  for insert to authenticated
  with check (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists agenda_update on public.meeting_agenda_items;
create policy agenda_update on public.meeting_agenda_items
  for update to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin())
  with check (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists agenda_delete on public.meeting_agenda_items;
create policy agenda_delete on public.meeting_agenda_items
  for delete to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin());

-- ── meeting_actions: attendee/admin full CRUD ──────────────
drop policy if exists actions_select on public.meeting_actions;
create policy actions_select on public.meeting_actions
  for select to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists actions_insert on public.meeting_actions;
create policy actions_insert on public.meeting_actions
  for insert to authenticated
  with check (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists actions_update on public.meeting_actions;
create policy actions_update on public.meeting_actions
  for update to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin())
  with check (public.mh_is_attendee(meeting_id) or public.mh_is_admin());
drop policy if exists actions_delete on public.meeting_actions;
create policy actions_delete on public.meeting_actions
  for delete to authenticated
  using (public.mh_is_attendee(meeting_id) or public.mh_is_admin());

-- ── kpi_entries: attendee-of-linked-meeting / admin CRUD ───
drop policy if exists kpi_entries_select on public.kpi_entries;
create policy kpi_entries_select on public.kpi_entries
  for select to authenticated
  using ((meeting_id is not null and public.mh_is_attendee(meeting_id)) or public.mh_is_admin());
drop policy if exists kpi_entries_insert on public.kpi_entries;
create policy kpi_entries_insert on public.kpi_entries
  for insert to authenticated
  with check ((meeting_id is not null and public.mh_is_attendee(meeting_id)) or public.mh_is_admin());
drop policy if exists kpi_entries_update on public.kpi_entries;
create policy kpi_entries_update on public.kpi_entries
  for update to authenticated
  using ((meeting_id is not null and public.mh_is_attendee(meeting_id)) or public.mh_is_admin())
  with check ((meeting_id is not null and public.mh_is_attendee(meeting_id)) or public.mh_is_admin());
drop policy if exists kpi_entries_delete on public.kpi_entries;
create policy kpi_entries_delete on public.kpi_entries
  for delete to authenticated
  using ((meeting_id is not null and public.mh_is_attendee(meeting_id)) or public.mh_is_admin());

-- ── Definitions: read for staff, write for admin ───────────
-- kpis
drop policy if exists kpis_select on public.kpis;
create policy kpis_select on public.kpis
  for select to authenticated using (true);
drop policy if exists kpis_write on public.kpis;
create policy kpis_write on public.kpis
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());

-- meeting_templates
drop policy if exists templates_select on public.meeting_templates;
create policy templates_select on public.meeting_templates
  for select to authenticated using (true);
drop policy if exists templates_write on public.meeting_templates;
create policy templates_write on public.meeting_templates
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());

-- meeting_template_items
drop policy if exists template_items_select on public.meeting_template_items;
create policy template_items_select on public.meeting_template_items
  for select to authenticated using (true);
drop policy if exists template_items_write on public.meeting_template_items;
create policy template_items_write on public.meeting_template_items
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());

-- meeting_series_templates
drop policy if exists series_templates_select on public.meeting_series_templates;
create policy series_templates_select on public.meeting_series_templates
  for select to authenticated using (true);
drop policy if exists series_templates_write on public.meeting_series_templates;
create policy series_templates_write on public.meeting_series_templates
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());

-- meeting_series_kpis
drop policy if exists series_kpis_select on public.meeting_series_kpis;
create policy series_kpis_select on public.meeting_series_kpis
  for select to authenticated using (true);
drop policy if exists series_kpis_write on public.meeting_series_kpis;
create policy series_kpis_write on public.meeting_series_kpis
  for all to authenticated
  using (public.mh_is_admin()) with check (public.mh_is_admin());
