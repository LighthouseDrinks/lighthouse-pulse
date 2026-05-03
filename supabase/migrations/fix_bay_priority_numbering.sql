-- Renumber bay_waitlist_priority for active (planning / scheduled) jobs
-- that have not yet started, starting from 1 in current priority order.
-- Run BEFORE deploying the updated Schedule IIFE.

WITH ranked AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      ORDER BY bay_waitlist_priority ASC NULLS LAST, created_at ASC
    ) AS new_priority
  FROM   jobs
  WHERE  stage IN ('planning', 'scheduled')
    AND  actual_start IS NULL
)
UPDATE jobs
SET    bay_waitlist_priority = ranked.new_priority
FROM   ranked
WHERE  jobs.id = ranked.id;
