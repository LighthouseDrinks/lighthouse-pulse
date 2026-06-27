-- ============================================================
-- clock_events_guard — hardens the staff clock-in / clock-out
-- / break system. Adds the missing schema if not already
-- present, RLS policies, a same-type 5s dedupe trigger,
-- a SECURITY DEFINER RPC that validates transitions, an audit
-- trigger that stamps edited_by / edited_at on every UPDATE,
-- and a future-timestamp CHECK constraint.
--
-- POLICY: forgotten clock-outs are NOT auto-closed. They stay
-- open until the user clocks out or a manager edits the
-- timesheet. The dashboard surfaces a "still clocked in"
-- banner so the situation is always visible.
--
-- IDEMPOTENT: safe to re-run. Uses IF NOT EXISTS / DROP IF
-- EXISTS / CREATE OR REPLACE everywhere.
--
-- TRIGGER vs RPC split:
--   * The trigger only enforces 5-second same-type dedupe so
--     accidental double-taps never reach the table. It applies
--     to every code path (live UI, admin "Edit day" modal, EF).
--   * The full transition logic (clock_in must follow
--     clock_out, break_end must follow break_start, etc.) lives
--     in clock_event_insert() and runs ONLY for the live UI.
--   * Admin direct PostgREST edits intentionally bypass the
--     transition check so they can repair historical days.
-- ============================================================

-- ── Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ── 1. Table (idempotent — create if missing, otherwise add the new columns)
CREATE TABLE IF NOT EXISTS public.clock_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_type      text NOT NULL,
  timestamp       timestamptz NOT NULL DEFAULT now(),
  within_geofence boolean,
  synthetic       boolean NOT NULL DEFAULT false,
  edited_by       uuid REFERENCES auth.users(id),
  edited_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.clock_events
  ADD COLUMN IF NOT EXISTS synthetic       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS edited_by       uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS edited_at       timestamptz,
  ADD COLUMN IF NOT EXISTS created_at      timestamptz NOT NULL DEFAULT now();

-- Replace any pre-existing CHECK with the canonical one
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'clock_events_event_type_check'
       OR conname = 'clock_events_event_type_chk'
  ) THEN
    EXECUTE 'ALTER TABLE public.clock_events DROP CONSTRAINT IF EXISTS clock_events_event_type_check';
    EXECUTE 'ALTER TABLE public.clock_events DROP CONSTRAINT IF EXISTS clock_events_event_type_chk';
  END IF;
END $$;

ALTER TABLE public.clock_events
  ADD CONSTRAINT clock_events_event_type_check
  CHECK (event_type IN ('clock_in','clock_out','break_start','break_end'));

CREATE INDEX IF NOT EXISTS clock_events_user_ts_idx
  ON public.clock_events (user_id, timestamp DESC);

-- ── 2. updated_at-style audit trigger ───────────────────────
CREATE OR REPLACE FUNCTION public.clock_events_set_edit_meta()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.edited_by := auth.uid();
  NEW.edited_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS clock_events_edit_meta ON public.clock_events;
CREATE TRIGGER clock_events_edit_meta
  BEFORE UPDATE ON public.clock_events
  FOR EACH ROW EXECUTE FUNCTION public.clock_events_set_edit_meta();

-- ── 3. Dedupe trigger (same-type within 5 s) ────────────────
CREATE OR REPLACE FUNCTION public.clock_events_dedupe()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prev_ts timestamptz;
BEGIN
  SELECT timestamp INTO v_prev_ts
    FROM public.clock_events
   WHERE user_id    = NEW.user_id
     AND event_type = NEW.event_type
     AND timestamp >= NEW.timestamp - interval '5 seconds'
     AND timestamp <= NEW.timestamp + interval '5 seconds'
   ORDER BY timestamp DESC
   LIMIT 1;
  IF v_prev_ts IS NOT NULL THEN
    RAISE EXCEPTION 'CLOCK_DEDUPE: same event_type % already exists within 5s for this user', NEW.event_type
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS clock_events_dedupe_trig ON public.clock_events;
CREATE TRIGGER clock_events_dedupe_trig
  BEFORE INSERT ON public.clock_events
  FOR EACH ROW EXECUTE FUNCTION public.clock_events_dedupe();

-- ── 4. RLS ───────────────────────────────────────────────────
ALTER TABLE public.clock_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clock_events_own          ON public.clock_events;
DROP POLICY IF EXISTS clock_events_admin        ON public.clock_events;
DROP POLICY IF EXISTS clock_events_select_own   ON public.clock_events;
DROP POLICY IF EXISTS clock_events_insert_own   ON public.clock_events;
DROP POLICY IF EXISTS clock_events_select_all   ON public.clock_events;
DROP POLICY IF EXISTS clock_events_update_admin ON public.clock_events;
DROP POLICY IF EXISTS clock_events_delete_admin ON public.clock_events;
DROP POLICY IF EXISTS clock_events_insert_admin ON public.clock_events;

-- Owner: select + insert own rows. Owner cannot update/delete
-- their own historical rows (admin operation only).
CREATE POLICY clock_events_select_own ON public.clock_events
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY clock_events_insert_own ON public.clock_events
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Timesheet admins: full access. Read jsonb permission key
-- "timesheet_edit" from the roles table, matching exactly what
-- the front-end checks at index.html (canEditTs()).
CREATE POLICY clock_events_select_all ON public.clock_events
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

CREATE POLICY clock_events_update_admin ON public.clock_events
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

CREATE POLICY clock_events_delete_admin ON public.clock_events
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

-- Admins also need to be able to INSERT for other users (admin add).
CREATE POLICY clock_events_insert_admin ON public.clock_events
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.roles r
      JOIN public.app_users u ON u.role = r.key
      WHERE u.auth_user_id = auth.uid()
        AND (r.permissions->>'timesheet_edit') = '1'
    )
  );

-- ── 5. clock_event_insert RPC (live UI path, transition-checked)
--
-- The front-end calls window.db.rpc('clock_event_insert', {...})
-- which routes here. On validation failure we raise an error
-- prefixed CLOCK_INVALID_TRANSITION or CLOCK_DEDUPE; the front
-- end translates those into friendly toasts.
CREATE OR REPLACE FUNCTION public.clock_event_insert(
  p_event_type      text,
  p_within_geofence boolean
) RETURNS public.clock_events
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_now        timestamptz := now();
  v_prev_type  text;
  v_prev_ts    timestamptz;
  v_row        public.clock_events;
  v_ok         boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'CLOCK_NOT_AUTHENTICATED' USING ERRCODE = 'P0001';
  END IF;
  IF p_event_type NOT IN ('clock_in','clock_out','break_start','break_end') THEN
    RAISE EXCEPTION 'CLOCK_INVALID_TYPE' USING ERRCODE = 'P0001';
  END IF;

  -- Most recent event for this user. No artificial time window: if the user
  -- forgot to clock out yesterday, we want this check to see it and block a
  -- second clock_in. The only resolution is the user themselves tapping
  -- Clock Out, or a manager fixing the timesheet.
  SELECT event_type, timestamp
    INTO v_prev_type, v_prev_ts
    FROM public.clock_events
   WHERE user_id = v_uid
   ORDER BY timestamp DESC
   LIMIT 1;

  -- Transition gate
  IF p_event_type = 'clock_in' THEN
    v_ok := (v_prev_type IS NULL OR v_prev_type = 'clock_out');
  ELSIF p_event_type = 'clock_out' THEN
    v_ok := (v_prev_type IN ('clock_in','break_end','break_start'));
  ELSIF p_event_type = 'break_start' THEN
    v_ok := (v_prev_type IN ('clock_in','break_end'));
  ELSIF p_event_type = 'break_end' THEN
    v_ok := (v_prev_type = 'break_start');
  END IF;

  -- Specific error codes per invalid transition so the front-end can show
  -- actionable text. The catch-all is CLOCK_INVALID_TRANSITION.
  IF NOT v_ok THEN
    IF p_event_type = 'clock_in' AND v_prev_type IN ('clock_in','break_end') THEN
      RAISE EXCEPTION 'CLOCK_STILL_CLOCKED_IN' USING ERRCODE = 'P0001';
    ELSIF p_event_type = 'clock_in' AND v_prev_type = 'break_start' THEN
      RAISE EXCEPTION 'CLOCK_STILL_ON_BREAK' USING ERRCODE = 'P0001';
    ELSIF p_event_type = 'break_start' AND v_prev_type = 'break_start' THEN
      RAISE EXCEPTION 'CLOCK_STILL_ON_BREAK' USING ERRCODE = 'P0001';
    ELSIF p_event_type = 'break_start' AND (v_prev_type IS NULL OR v_prev_type = 'clock_out') THEN
      RAISE EXCEPTION 'CLOCK_NOT_CLOCKED_IN' USING ERRCODE = 'P0001';
    ELSIF p_event_type = 'break_end' AND v_prev_type <> 'break_start' THEN
      RAISE EXCEPTION 'CLOCK_NOT_ON_BREAK' USING ERRCODE = 'P0001';
    ELSIF p_event_type = 'clock_out' THEN
      RAISE EXCEPTION 'CLOCK_NOT_CLOCKED_IN' USING ERRCODE = 'P0001';
    ELSE
      RAISE EXCEPTION 'CLOCK_INVALID_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  INSERT INTO public.clock_events (user_id, event_type, timestamp, within_geofence)
  VALUES (v_uid, p_event_type, v_now, p_within_geofence)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clock_event_insert(text, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.clock_event_insert(text, boolean) FROM anon;

-- ── 6. Future-timestamp guard ──────────────────────────────
-- Defence in depth against bad client clocks or admin edits that drop a
-- clock event in the future. 5-minute wall-clock slack to avoid races
-- between client wall time and server `now()`.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'clock_events_no_future') THEN
    ALTER TABLE public.clock_events DROP CONSTRAINT clock_events_no_future;
  END IF;
END $$;
ALTER TABLE public.clock_events
  ADD CONSTRAINT clock_events_no_future
  CHECK (timestamp <= now() + interval '5 minutes') NOT VALID;

-- NOTE: No nightly auto-close cron. Per policy, a forgotten clock_out
-- stays open until the user themselves clocks out or a manager edits the
-- timesheet. The reducer + UI surface a "still clocked in" banner so the
-- situation is always visible.

-- ── End of migration ────────────────────────────────────────
