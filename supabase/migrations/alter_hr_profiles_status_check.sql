-- Extend hr_profiles status check constraint to allow 'pending_termination'.
-- The original constraint only permitted 'active' and 'terminated'.

ALTER TABLE hr_profiles
  DROP CONSTRAINT IF EXISTS hr_profiles_status_check;

ALTER TABLE hr_profiles
  ADD CONSTRAINT hr_profiles_status_check
  CHECK (status IN ('active', 'pending_termination', 'terminated'));
