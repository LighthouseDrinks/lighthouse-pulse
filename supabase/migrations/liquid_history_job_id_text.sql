-- ============================================================
-- liquid_history.job_id: change uuid -> text.
--
-- Root cause: liquid_history.job_id was uuid, but jobs use text IDs
-- like 'JOB-12'. So job-linked history writes (bottling close-out,
-- sign-off dilution/blend) could not store the job reference - the
-- insert would fail a type cast - and the code worked around it by
-- omitting job_id and stuffing the reference into the free-text notes.
-- That made per-job audit queries impossible.
--
-- This mirrors the identical fix already applied to bom_history in
-- bom_history_rls.sql (bom_id uuid -> text).
--
-- Safe: the column currently holds zero non-null rows, so the cast is
-- a no-op on data, and no views depend on it. Idempotent - re-running
-- when the column is already text is harmless.
-- ============================================================

ALTER TABLE public.liquid_history
  ALTER COLUMN job_id TYPE text USING job_id::text;
