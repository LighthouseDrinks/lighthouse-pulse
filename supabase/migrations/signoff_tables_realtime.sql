-- ============================================================
-- Enable Supabase realtime on the sign-off gate tables.
--
-- The frontend already subscribes to these tables (the
-- `signoff_gates` and `schedule_jobs` channels) so that the
-- BOM / Supply Chain / Liquid pills turn green automatically.
-- However the `supabase_realtime` publication only contained
-- `jobs` and `line_events`, so no change events were ever
-- broadcast for the sign-off tables and a manual page refresh
-- was required.
--
-- Adding these tables to the publication closes that gap.
-- Realtime still respects RLS, so only rows a user may already
-- SELECT are delivered.
--
-- Safe to re-run: each ADD TABLE is guarded so the migration is
-- idempotent and a table already in the publication is skipped.
-- ============================================================

DO $$
DECLARE
  t text;
  tbls text[] := ARRAY[
    'job_bom_approvals',
    'job_drygoods_prep',
    'job_liquid_signoff',
    'job_tasks'
  ];
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END
$$;
