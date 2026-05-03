-- Add status column to app_users to support employee termination access revocation.
-- 'active' is the default for all existing and new users.
-- When an employee is terminated, this is set to 'terminated' and login is blocked.

ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
