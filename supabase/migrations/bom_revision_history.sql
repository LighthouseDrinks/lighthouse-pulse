-- ============================================================
-- BOM Revision History, Client Edit Requests & Per-Job BOM Approvals
-- ============================================================

-- 1. Add revision tracking columns to boms
ALTER TABLE boms
  ADD COLUMN IF NOT EXISTS revision_number INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS revised_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS revised_by      TEXT;

-- 2. Add revision_number to bom_history so each entry is tagged to a revision
ALTER TABLE bom_history
  ADD COLUMN IF NOT EXISTS revision_number INTEGER;

-- 3. Client-initiated BOM edit requests (on already-approved BOMs)
CREATE TABLE IF NOT EXISTS client_bom_edit_requests (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  bom_id         TEXT        NOT NULL,
  client_id      TEXT        NOT NULL,
  requested_by   TEXT        NOT NULL,
  requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  request_notes  TEXT,
  status         TEXT        NOT NULL DEFAULT 'pending',
  -- status: pending | approved_client | approved_staff | rejected
  reviewed_by    TEXT,
  reviewed_at    TIMESTAMPTZ,
  review_notes   TEXT,
  assigned_to    TEXT
  -- assigned_to: client | staff (set on approval)
);

-- 4. Per-job BOM client confirmation (mirrors job_label_approvals pattern)
CREATE TABLE IF NOT EXISTS job_bom_approvals (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id                TEXT        NOT NULL,
  bom_id                TEXT        NOT NULL,
  approval_token        UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  client_email_to       TEXT,
  client_email_sent_at  TIMESTAMPTZ,
  client_decision       TEXT,
  -- client_decision: approved | flagged
  client_decided_at     TIMESTAMPTZ,
  client_approver_name  TEXT,
  client_notes          TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for fast token lookups on public page
CREATE INDEX IF NOT EXISTS job_bom_approvals_token_idx ON job_bom_approvals (approval_token);
-- Index for job lookups
CREATE INDEX IF NOT EXISTS job_bom_approvals_job_idx ON job_bom_approvals (job_id);
