-- ============================================================
-- SECURITY DEFINER view lockdown — close the staff-data leak via
-- v_tasks and v_clock_status (audit finding C-1a).
--
-- Both views were defined SECURITY DEFINER (so they run as the view
-- owner and BYPASS the caller's RLS) and were granted SELECT to
-- `anon` AND `authenticated`. That let any client portal JWT — and
-- even an unauthenticated holder of the publishable anon key — read:
--   * v_tasks        : every staff task (titles, assignee/assigner
--                      names, linked job product names, notes)
--   * v_clock_status : every staff member's latest clock in/out and
--                      geofence flag (attendance / PII)
--
-- Fix: flip both to security_invoker so they inherit the CALLER's RLS,
-- and revoke the anon grant. After this:
--   * staff (authenticated, is_staff()) — unchanged: `tasks` has
--     staff_see_all_tasks/staff_all (is_staff()); `clock_events` has
--     clock_events_select_own + admin-all.
--   * client (role='client') and anon — get 0 rows.
--
-- VERIFIED SAFE before writing:
--   * Neither view is referenced anywhere in the application
--     (index.html / plant-display.html) — no UI dependency.
--   * The staff "still clocked in" widget reads public.clock_events
--     directly (own-row policy), NOT v_clock_status, so it is
--     unaffected.
--
-- DELIBERATELY NOT TOUCHED HERE (separate follow-up, finding C-1b):
--   * line_throughput_live / line_hourly_totals + public.line_events.
--     These are read ONLY by the TV kiosk (plant-display.html), whose
--     fetch helper falls back to the anon key when its session is not
--     yet established. They currently render even when kiosk auth
--     fails precisely because the views are SECURITY DEFINER + granted
--     to anon. Locking them down requires hardening the kiosk auth
--     first (guarantee a staff session, or show a "not connected"
--     state) so we never blank the production-floor TV. The data is
--     also the least sensitive (aggregate bottles/hour, no PII).
--   * xero_connection_public / ecommerce_stores_public — appear to be
--     intentional sanitised public views; review separately.
--
-- ROLLBACK (restores prior wide-open behaviour):
--   ALTER VIEW IF EXISTS public.v_tasks        SET (security_invoker = off);
--   ALTER VIEW IF EXISTS public.v_clock_status SET (security_invoker = off);
--   GRANT SELECT ON public.v_tasks        TO anon;
--   GRANT SELECT ON public.v_clock_status TO anon;
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── v_tasks ─────────────────────────────────────────────────
ALTER VIEW IF EXISTS public.v_tasks SET (security_invoker = on);

-- ── v_clock_status ──────────────────────────────────────────
ALTER VIEW IF EXISTS public.v_clock_status SET (security_invoker = on);

-- ── Drop the anon grant (authenticated keeps SELECT; RLS now
--    governs which rows it actually sees) ───────────────────
DO $mig$
BEGIN
  IF to_regclass('public.v_tasks') IS NOT NULL THEN
    EXECUTE 'REVOKE SELECT ON public.v_tasks FROM anon';
  END IF;
  IF to_regclass('public.v_clock_status') IS NOT NULL THEN
    EXECUTE 'REVOKE SELECT ON public.v_clock_status FROM anon';
  END IF;
END
$mig$;
