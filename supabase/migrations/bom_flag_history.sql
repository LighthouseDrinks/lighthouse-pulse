ALTER TABLE job_bom_approvals
  ADD COLUMN IF NOT EXISTS flag_history JSONB NOT NULL DEFAULT '[]'::jsonb;
