-- Add liquid exclusion / bypass columns to job_liquid_signoff
-- Used when liquid was never processed through the system and sign-off is not applicable.
ALTER TABLE job_liquid_signoff
  ADD COLUMN IF NOT EXISTS liquid_excluded   boolean      DEFAULT false,
  ADD COLUMN IF NOT EXISTS excluded_by       text,
  ADD COLUMN IF NOT EXISTS excluded_note     text,
  ADD COLUMN IF NOT EXISTS excluded_at       timestamptz;
