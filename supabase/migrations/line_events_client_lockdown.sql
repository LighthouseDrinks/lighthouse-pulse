-- ============================================================
-- line_events — restrict production telemetry to staff (audit C-1b).
--
-- line_events carried two permissive SELECT policies:
--     line_events_read              USING (true)  -- authenticated
--     plant_display_read_line_events USING (true) -- authenticated
-- so any logged-in client-portal JWT could read raw production line
-- telemetry (per-line bottle counts + timestamps) across every line.
--
-- Fix: drop the open SELECT policies and replace with a staff-only
-- SELECT (is_staff()). Inserts stay service-role only (the bottle-count
-- webhook writes with the service key, which bypasses RLS regardless).
--
-- SAFE:
--   * line_events / the line_* views are NOT referenced anywhere in
--     index.html (staff dashboard does not read them).
--   * The plant-display TV kiosk authenticates as a staff account
--     (plant-display.html signInWithPassword), so is_staff() is true and
--     it keeps reading the throughput views. The companion migration
--     line_view_security_invoker.sql flips those views to
--     security_invoker so they inherit this staff scope.
--
-- Idempotent / safe to re-run.
-- ============================================================

ALTER TABLE public.line_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS line_events_read              ON public.line_events;
DROP POLICY IF EXISTS plant_display_read_line_events ON public.line_events;
DROP POLICY IF EXISTS line_events_staff_read        ON public.line_events;

CREATE POLICY line_events_staff_read ON public.line_events
  FOR SELECT TO authenticated
  USING (public.is_staff());

-- Keep the existing service-role insert policy (line_events_insert) as-is.
