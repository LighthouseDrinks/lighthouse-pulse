-- ============================================================
-- timecard_requests — backs the "Send timecard link" flow in the
-- Weekly Attendance report.
--
-- A manager sends an employee a magic link (token) to fill in their
-- real clock-in/out/break times for days with missing or mismatched
-- punches. The employee's submission is stored here as a pending
-- correction request; it does NOT touch clock_events until a manager
-- approves it in the report. This preserves the tamper-resistance of
-- the geofenced clock (see clock_events_guard.sql — staff cannot edit
-- their own historical clock rows; only timesheet_edit admins can).
--
-- Token is the security boundary for the unauthenticated correction
-- page. The timecard edge function (deployed --no-verify-jwt) reads
-- and writes this table with the service role, validating the token.
-- Front-end (managers) access it under RLS gated on timesheet_edit,
-- matching the clock_events admin policies exactly.
--
-- IDEMPOTENT: safe to re-run.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── 1. Table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.timecard_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token             text NOT NULL UNIQUE,
  user_id           uuid NOT NULL,              -- employee = auth.users.id (clock_events.user_id)
  app_user_id       uuid,                       -- app_users.id (roster_shifts.user_id)
  employee_name     text,
  week_start        date NOT NULL,              -- Monday (YYYY-MM-DD) of the week being corrected
  flagged           jsonb,                      -- snapshot of problem days at send time (for the email)
  status            text NOT NULL DEFAULT 'sent',
  submitted_payload jsonb,                      -- the days/times the employee entered
  submitted_at      timestamptz,
  created_by        uuid,                        -- manager auth.users.id who sent it
  created_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL,
  reviewed_by       uuid,                        -- manager auth.users.id who approved/rejected
  reviewed_at       timestamptz
);

-- Additive guards in case an older/partial table already exists.
ALTER TABLE public.timecard_requests
  ADD COLUMN IF NOT EXISTS app_user_id       uuid,
  ADD COLUMN IF NOT EXISTS employee_name     text,
  ADD COLUMN IF NOT EXISTS flagged           jsonb,
  ADD COLUMN IF NOT EXISTS submitted_payload jsonb,
  ADD COLUMN IF NOT EXISTS submitted_at      timestamptz,
  ADD COLUMN IF NOT EXISTS created_by        uuid,
  ADD COLUMN IF NOT EXISTS reviewed_by       uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at       timestamptz;

-- Canonical status check.
ALTER TABLE public.timecard_requests
  DROP CONSTRAINT IF EXISTS timecard_requests_status_check;
ALTER TABLE public.timecard_requests
  ADD CONSTRAINT timecard_requests_status_check
  CHECK (status IN ('sent','submitted','approved','rejected','expired'));

CREATE INDEX IF NOT EXISTS timecard_requests_user_week_idx
  ON public.timecard_requests (user_id, week_start);
CREATE INDEX IF NOT EXISTS timecard_requests_status_idx
  ON public.timecard_requests (status, week_start);
CREATE INDEX IF NOT EXISTS timecard_requests_token_idx
  ON public.timecard_requests (token);

-- ── 2. RLS ───────────────────────────────────────────────────
-- Managers with timesheet_edit get full access (send, list, approve).
-- There is intentionally NO anon/owner policy: the unauthenticated
-- correction page goes through the timecard edge function, which uses
-- the service role and validates the token itself.
ALTER TABLE public.timecard_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS timecard_requests_select_admin ON public.timecard_requests;
DROP POLICY IF EXISTS timecard_requests_insert_admin ON public.timecard_requests;
DROP POLICY IF EXISTS timecard_requests_update_admin ON public.timecard_requests;
DROP POLICY IF EXISTS timecard_requests_delete_admin ON public.timecard_requests;

CREATE POLICY timecard_requests_select_admin ON public.timecard_requests
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

CREATE POLICY timecard_requests_insert_admin ON public.timecard_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

CREATE POLICY timecard_requests_update_admin ON public.timecard_requests
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  )
  WITH CHECK (true);

CREATE POLICY timecard_requests_delete_admin ON public.timecard_requests
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.timecard_requests TO authenticated;
