-- ============================================================
-- clock_events_audit — append-only audit log of every change to
-- public.clock_events. Captures who made the change and when,
-- with the full before/after row state for INSERT / UPDATE /
-- DELETE. The audit row is written by a trigger so there is no
-- way for application code to skip it.
--
-- Why: managers can already edit/delete clock_events via the
-- timesheet UI. The clock_events.edited_by + edited_at columns
-- only record the most-recent UPDATE — they don't tell us:
--   * who DELETED a row (the row is gone)
--   * who INSERTED a row on behalf of someone else
--   * the prior values of a row that was edited multiple times
--
-- This migration is purely additive. No changes to clock_events,
-- the RPC, or any existing triggers/policies.
--
-- IDEMPOTENT: safe to re-run.
-- ============================================================

-- ── 1. Audit table ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clock_events_audit (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid        NOT NULL,
  action      text        NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_row     jsonb,
  new_row     jsonb,
  editor_id   uuid        REFERENCES auth.users(id),
  action_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS clock_events_audit_event_idx
  ON public.clock_events_audit (event_id, action_at DESC);

CREATE INDEX IF NOT EXISTS clock_events_audit_editor_idx
  ON public.clock_events_audit (editor_id, action_at DESC);

-- ── 2. Audit trigger ─────────────────────────────────────────
-- One function handles all three actions. SECURITY DEFINER so it
-- can always write to the audit table regardless of the caller's
-- RLS context (RLS still applies to SELECT — see policies below).
CREATE OR REPLACE FUNCTION public.clock_events_log_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_action text := TG_OP;
  v_eid    uuid;
  v_old    jsonb;
  v_new    jsonb;
BEGIN
  IF v_action = 'INSERT' THEN
    v_eid := NEW.id;
    v_old := NULL;
    v_new := to_jsonb(NEW);
  ELSIF v_action = 'UPDATE' THEN
    v_eid := NEW.id;
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
  ELSE  -- DELETE
    v_eid := OLD.id;
    v_old := to_jsonb(OLD);
    v_new := NULL;
  END IF;

  INSERT INTO public.clock_events_audit (event_id, action, old_row, new_row, editor_id)
  VALUES (v_eid, v_action, v_old, v_new, auth.uid());

  -- Trigger return convention: NEW for INSERT/UPDATE, OLD for DELETE.
  IF v_action = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS clock_events_audit_trig ON public.clock_events;
CREATE TRIGGER clock_events_audit_trig
  AFTER INSERT OR UPDATE OR DELETE ON public.clock_events
  FOR EACH ROW EXECUTE FUNCTION public.clock_events_log_audit();

-- ── 3. RLS ───────────────────────────────────────────────────
-- The audit table is append-only by trigger. The only thing
-- application code should ever do is SELECT, and only timesheet
-- admins should be able to do that. No policy is created for
-- INSERT / UPDATE / DELETE — RLS denies them by default. The
-- SECURITY DEFINER trigger bypasses RLS for its single INSERT,
-- which is the only way rows can ever appear here.
ALTER TABLE public.clock_events_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clock_events_audit_select_admin ON public.clock_events_audit;
CREATE POLICY clock_events_audit_select_admin ON public.clock_events_audit
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

-- Explicitly REVOKE direct writes from authenticated. Belt-and-
-- braces in case RLS is ever turned off in error.
REVOKE INSERT, UPDATE, DELETE ON public.clock_events_audit FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.clock_events_audit FROM anon;

-- ── End of migration ────────────────────────────────────────
