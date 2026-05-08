ALTER TABLE leave_requests
  ADD COLUMN IF NOT EXISTS leave_category varchar(50) DEFAULT 'annual',
  ADD COLUMN IF NOT EXISTS applied_by_manager boolean DEFAULT false;
