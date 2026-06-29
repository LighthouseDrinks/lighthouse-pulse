-- ============================================================
-- Tighten always-true WITH CHECK on the timesheet-admin UPDATE
-- policies (audit finding H-2 / advisor rls_policy_always_true).
--
-- clock_events_update_admin and timecard_requests_update_admin both
-- gate their USING clause behind the `timesheet_edit` permission, but
-- carry WITH CHECK (true). The advisor flags this as effectively
-- bypassing RLS for the post-update row: a timesheet-edit admin could
-- write a row that no longer satisfies the policy (e.g. re-point
-- user_id arbitrarily). It is NOT client-exploitable today — the USING
-- clause already restricts the visible rows to timesheet-edit admins,
-- and a portal client has no role with timesheet_edit — so this is
-- pure defense-in-depth: make WITH CHECK mirror USING.
--
-- VERIFIED (live pg_policy) — both USING clauses are identical:
--   EXISTS (SELECT 1 FROM roles r JOIN app_users u ON u.role = r.key
--           WHERE u.auth_user_id = auth.uid()
--             AND (r.permissions ->> 'timesheet_edit') = '1')
--
-- ROLLBACK (restores prior WITH CHECK (true)):
--   ALTER POLICY clock_events_update_admin     ON public.clock_events     WITH CHECK (true);
--   ALTER POLICY timecard_requests_update_admin ON public.timecard_requests WITH CHECK (true);
--
-- Idempotent / safe to re-run (ALTER POLICY just re-sets the clause).
-- ============================================================

-- ── clock_events ────────────────────────────────────────────
DO $mig$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'clock_events'
      AND policyname = 'clock_events_update_admin'
  ) THEN
    ALTER POLICY clock_events_update_admin ON public.clock_events
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.roles r
          JOIN public.app_users u ON u.role = r.key
          WHERE u.auth_user_id = auth.uid()
            AND (r.permissions ->> 'timesheet_edit') = '1'
        )
      );
  END IF;
END
$mig$;

-- ── timecard_requests ───────────────────────────────────────
DO $mig$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'timecard_requests'
      AND policyname = 'timecard_requests_update_admin'
  ) THEN
    ALTER POLICY timecard_requests_update_admin ON public.timecard_requests
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.roles r
          JOIN public.app_users u ON u.role = r.key
          WHERE u.auth_user_id = auth.uid()
            AND (r.permissions ->> 'timesheet_edit') = '1'
        )
      );
  END IF;
END
$mig$;
