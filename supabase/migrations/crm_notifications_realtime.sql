-- ============================================================
-- Enable Supabase realtime on crm_notifications.
--
-- The notification bell badge (top-right red counter) relied
-- solely on a 45s, visibility-gated poll to discover new rows.
-- When the assignee marked a task complete, the row that tells
-- the task's sender about it was written correctly, but the
-- sender's badge could lag up to ~45s and would not refresh on
-- returning to the tab -- so the alert felt unreliable.
--
-- The frontend now subscribes to a `crm_notifications_<user>`
-- channel (filtered to the user's own rows) for near-instant
-- badge updates, but the `supabase_realtime` publication did not
-- include this table, so no change events were ever broadcast.
--
-- Adding it to the publication closes that gap. Realtime still
-- respects RLS (the `staff_all` policy), so only rows a user may
-- already SELECT are delivered.
--
-- Safe to re-run: the ADD TABLE is guarded so the migration is
-- idempotent and a table already in the publication is skipped.
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'crm_notifications'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.crm_notifications';
  END IF;
END
$$;
