-- Independent Liquid Ready override. Defaults to Job Ready; when set later
-- than the dry-goods Job Ready, that date becomes job_ready_date.
ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS liquid_ready_manual boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN jobs.liquid_ready_manual IS
  'True when liquid_ready_date was manually overridden; Reset remirrors to Job Ready.';

COMMENT ON COLUMN jobs.liquid_ready_date IS
  'Expected liquid-on-site date. Defaults to job_ready_date; when overridden later than dry-goods Job Ready, that date becomes job_ready_date.';
