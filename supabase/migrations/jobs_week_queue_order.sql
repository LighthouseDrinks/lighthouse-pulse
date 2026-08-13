-- Manual order for the Jobs "this week" block. Schedule Next 5 mirrors it.
-- Positions are only valid when week_queue_key is the current Monday.
ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS week_queue_pos integer,
  ADD COLUMN IF NOT EXISTS week_queue_key date;

COMMENT ON COLUMN jobs.week_queue_pos IS
  'Manual order within the current Jobs week block. Valid only when week_queue_key is this Monday.';
COMMENT ON COLUMN jobs.week_queue_key IS
  'Monday (UK week) that week_queue_pos belongs to. Ignored when stale.';
