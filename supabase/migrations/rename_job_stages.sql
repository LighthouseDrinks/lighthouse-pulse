-- Step 1: Drop the existing stage check constraint and replace it with one
-- that allows the new stage values (new, active) alongside the legacy
-- title-case values so old rows remain valid until fully migrated.
ALTER TABLE jobs DROP CONSTRAINT IF EXISTS jobs_stage_check;

ALTER TABLE jobs ADD CONSTRAINT jobs_stage_check CHECK (
  stage IN (
    'new', 'active', 'complete', 'on_hold', 'cancelled',
    -- legacy title-case values (pre-rename rows)
    'Intake', 'Job Prep', 'Pre-Production Signoff', 'Scheduled', 'In Production', 'Complete',
    -- previous lowercase values (in case migration runs before all rows are updated)
    'planning', 'scheduled'
  )
);

-- Step 2: Rename existing rows to the new stage values
UPDATE jobs SET stage = 'new'    WHERE stage = 'planning';
UPDATE jobs SET stage = 'active' WHERE stage = 'scheduled';
