-- ============================================================
-- Enable Supabase realtime on job_components.
--
-- The Jobs list Supply Chain column recomputes when Ordered /
-- Exclude / Allocate change. The frontend signoff_gates channel
-- already listens for job_components events; this adds the table
-- to the publication so those events are actually broadcast.
--
-- Safe to re-run: ADD TABLE is guarded if already published.
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'job_components'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.job_components;
  END IF;
END
$$;
