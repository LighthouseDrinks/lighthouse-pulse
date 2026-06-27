-- ============================================================
-- clock_events_transition_shadow — BEFORE INSERT trigger that
-- enforces clock_events transition rules on every insert path,
-- not just the clock_event_insert RPC. Logs every rejection to
-- clock_events_violations and then RAISEs CLOCK_INVALID_TRANSITION
-- (originally deployed in shadow mode; flipped to enforcement
-- on 2026-06-02 after a week of clean observation).
--
-- The clock_event_insert RPC is the canonical path for the live
-- UI; it already validates transitions. This trigger is the
-- defence-in-depth gate for direct PostgREST inserts:
--   1. Manager edits via the timesheet UI — these are
--      intentional repairs (e.g. inserting a forgotten
--      clock_out into yesterday). Bypassed entirely below
--      because the inserter holds timesheet_edit.
--   2. The fresh-insert path of the day-modal "Add day" flow
--      for the currently-selected user — same intent as (1),
--      same admin bypass.
--   3. Stale-client / external direct POSTs from non-admin
--      users: these are the back-door this trigger closes.
--      Rejected with CLOCK_INVALID_TRANSITION, logged for
--      forensic review.
--
-- The RLS clock_events_insert_own policy still allows owner
-- inserts that pass user_id = auth.uid(); the transition check
-- happens here, after that gate. So the trigger is mandatory
-- for correctness — RLS alone never enforced sequence.
--
-- IDEMPOTENT: safe to re-run.
-- ============================================================

-- ── 1. Violations log table ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clock_events_violations (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempted_event_type text        NOT NULL,
  prior_event_type     text,
  would_reject_reason  text        NOT NULL,
  attempted_at         timestamptz NOT NULL DEFAULT now(),
  inserter_id          uuid        REFERENCES auth.users(id),
  inserter_is_admin    boolean     NOT NULL
);

CREATE INDEX IF NOT EXISTS clock_events_violations_at_idx
  ON public.clock_events_violations (attempted_at DESC);

CREATE INDEX IF NOT EXISTS clock_events_violations_user_idx
  ON public.clock_events_violations (user_id, attempted_at DESC);

-- ── 2. Shadow trigger function ──────────────────────────────
-- BEFORE INSERT. Skips entirely for admins (timesheet_edit=1).
-- For non-admins, replicates the clock_event_insert transition
-- logic; on violation, INSERTs into clock_events_violations
-- and RETURNS NEW so the original insert still proceeds.
CREATE OR REPLACE FUNCTION public.clock_events_transition_shadow()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_inserter   uuid := auth.uid();
  v_is_admin   boolean := false;
  v_prev_type  text;
  v_ok         boolean := false;
  v_reason     text;
BEGIN
  -- Admin bypass: manager edits via the timesheet are intentional
  -- repairs and must not be logged as violations.
  IF v_inserter IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = v_inserter
        AND (r.permissions->>'timesheet_edit') = '1'
    ) INTO v_is_admin;
  END IF;

  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  -- Unknown event_type — the CHECK constraint catches this; nothing
  -- to log because the row would fail at insert time anyway.
  IF NEW.event_type NOT IN ('clock_in','clock_out','break_start','break_end') THEN
    RETURN NEW;
  END IF;

  -- Most recent event for this user prior to the new one's timestamp.
  -- Using NEW.timestamp (not now()) so retroactive admin inserts that
  -- somehow get past the admin bypass still log against the right
  -- predecessor.
  SELECT event_type
    INTO v_prev_type
    FROM public.clock_events
   WHERE user_id = NEW.user_id
     AND timestamp <  NEW.timestamp
   ORDER BY timestamp DESC
   LIMIT 1;

  -- Same transition table as clock_event_insert().
  IF NEW.event_type = 'clock_in' THEN
    v_ok := (v_prev_type IS NULL OR v_prev_type = 'clock_out');
  ELSIF NEW.event_type = 'clock_out' THEN
    v_ok := (v_prev_type IN ('clock_in','break_end','break_start'));
  ELSIF NEW.event_type = 'break_start' THEN
    v_ok := (v_prev_type IN ('clock_in','break_end'));
  ELSIF NEW.event_type = 'break_end' THEN
    v_ok := (v_prev_type = 'break_start');
  END IF;

  IF NOT v_ok THEN
    v_reason := 'attempted ' || NEW.event_type
             || ' after ' || COALESCE(v_prev_type, '(no prior event)');
    -- ENFORCEMENT MODE (since 2026-06-02). After one week of shadow logging
    -- caught only genuine bugs (3 stale-client direct PostgREST inserts of
    -- clock_in after break_end, none from admin edit paths), the trigger
    -- was flipped to actively reject. The client-side error translator maps
    -- CLOCK_INVALID_TRANSITION to a friendly toast.
    --
    -- Note: rejected attempts are NOT inserted into clock_events_violations
    -- because RAISE rolls back the entire transaction including any prior
    -- INSERT in this trigger. The historical violations table is preserved
    -- as a record of the shadow period; further forensic data lives in the
    -- application error log + clock_events_audit (for the attempts that
    -- DID succeed in the past).
    RAISE EXCEPTION 'CLOCK_INVALID_TRANSITION: %', v_reason
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS clock_events_transition_shadow_trig ON public.clock_events;
CREATE TRIGGER clock_events_transition_shadow_trig
  BEFORE INSERT ON public.clock_events
  FOR EACH ROW EXECUTE FUNCTION public.clock_events_transition_shadow();

-- ── 3. RLS on violations table ──────────────────────────────
ALTER TABLE public.clock_events_violations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clock_events_violations_select_admin ON public.clock_events_violations;
CREATE POLICY clock_events_violations_select_admin ON public.clock_events_violations
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

REVOKE INSERT, UPDATE, DELETE ON public.clock_events_violations FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.clock_events_violations FROM anon;

-- ── End of migration ────────────────────────────────────────
