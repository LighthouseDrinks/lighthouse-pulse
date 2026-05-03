-- Add termination detail columns to hr_profiles
-- These fields are captured via the termination modal when an admin terminates an employee.

ALTER TABLE hr_profiles
  ADD COLUMN IF NOT EXISTS termination_type      TEXT,
  ADD COLUMN IF NOT EXISTS last_working_day      DATE,
  ADD COLUMN IF NOT EXISTS notice_period         TEXT,
  ADD COLUMN IF NOT EXISTS final_pay_date        DATE,
  ADD COLUMN IF NOT EXISTS equipment_returned    BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS termination_notes     TEXT;
