-- Add active production tracking columns to the jobs table.
-- Run BEFORE deploying the updated Schedule IIFE.
-- All columns are nullable; total_paused_secs defaults to 0.

ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS paused_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS total_paused_secs  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS changeover_start   TIMESTAMPTZ;
