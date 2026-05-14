-- Add supplier column to job_components so the Supply Chain tab can save
-- the supplier name per component.
-- Safe to run multiple times — skips silently if the column already exists.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'job_components'
      AND column_name  = 'supplier'
  ) THEN
    ALTER TABLE public.job_components
      ADD COLUMN supplier text;
  END IF;
END $$;
