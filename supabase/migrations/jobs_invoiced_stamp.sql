-- Manual invoiced stamp on Jobs → Complete tab.
-- Once set in the UI, invoiced stays true and invoiced_by / invoiced_at record who marked it.

ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS invoiced boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS invoiced_by text,
  ADD COLUMN IF NOT EXISTS invoiced_at timestamptz;

COMMENT ON COLUMN public.jobs.invoiced IS 'Manual invoiced stamp on Jobs Complete tab';
