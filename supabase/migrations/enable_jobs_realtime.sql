-- Enable Supabase Realtime for the jobs table so the plant display
-- receives live updates when start / pause / resume / finish are pressed.
-- Run this in the Supabase SQL editor (project dashboard → SQL Editor).
-- Safe to run multiple times — skips silently if already a member.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'jobs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE jobs;
  END IF;
END $$;
