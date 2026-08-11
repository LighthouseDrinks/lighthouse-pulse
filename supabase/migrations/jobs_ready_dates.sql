-- Job Ready dating + schedule slot pin for auto Next-5
ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS job_ready_date date,
  ADD COLUMN IF NOT EXISTS job_ready_manual boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS liquid_ready_date date,
  ADD COLUMN IF NOT EXISTS schedule_slot_pinned boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN jobs.job_ready_date IS 'When all outstanding supply-chain inputs are expected on site (max ETA + liquid ready, or today if all on-site). Used for Jobs list / Next 5 ordering.';
COMMENT ON COLUMN jobs.job_ready_manual IS 'True when job_ready_date was manually overridden; Reset clears this and recomputes.';
COMMENT ON COLUMN jobs.liquid_ready_date IS 'Expected liquid-on-site date; participates in job_ready_date max.';
COMMENT ON COLUMN jobs.schedule_slot_pinned IS 'True when Next-5 schedule_slot was manually assigned; autofill will not displace.';

CREATE INDEX IF NOT EXISTS jobs_job_ready_date_idx ON jobs (job_ready_date ASC NULLS LAST);

-- Preserve any slots already assigned before autofill went live.
UPDATE jobs
SET schedule_slot_pinned = true
WHERE schedule_slot IS NOT NULL
  AND schedule_slot_pinned = false;
