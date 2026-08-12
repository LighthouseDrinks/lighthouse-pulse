-- ============================================================
-- Tighten "any authenticated user" policies to staff-only.
--
-- Several internal tables carried policies keyed on
-- `auth.role() = 'authenticated'`, which is TRUE for every logged-in
-- user — including external client-portal logins (role = 'client').
-- A client JWT could therefore read (and in some cases write) internal
-- production / CRM data via a direct PostgREST call. None of these
-- tables are used by the client portal or the TV kiosk (the kiosk
-- signs in as a staff account and only reads line_* views), so we
-- re-scope them to public.is_staff() (any active non-client app_user).
--
-- Tables covered:
--   * vessels            — SELECT / INSERT / UPDATE (no DELETE policy;
--                          coverage preserved, DELETE stays denied)
--   * deal_next_steps    — FOR ALL (CRM)
--   * downtime_logs      — SELECT / INSERT (production downtime)
--   * peat_documents     — drop the wide SELECT; the existing
--     peat_chunks          "Staff can manage ..." (role <> 'client')
--                          policy already covers staff read+write.
--
-- Also removes two redundant duplicate policies (no access change):
--   * clients.staff_all_clients   — identical to clients.staff_all
--   * hr_profiles."Admins can read all hr_profiles" — strict subset
--       of hr_profiles."Admins can manage all hr_profiles" (FOR ALL)
--
-- NOTE: hr_profiles."hr_own" and geofence_settings."geofence_update"
-- contain a dead sub-clause comparing app_users.id = auth.uid()
-- (app_users keys auth users via auth_user_id, not id). Left in place
-- deliberately — cleaning it requires verifying hr_profiles.user_id /
-- auth_user_id data consistency first, and is not a security exposure.
--
-- ROLLBACK: recreate the dropped policies with
-- USING/WITH CHECK (auth.role() = 'authenticated').
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── vessels ─────────────────────────────────────────────────
ALTER TABLE public.vessels ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vessels_select ON public.vessels;
DROP POLICY IF EXISTS vessels_insert ON public.vessels;
DROP POLICY IF EXISTS vessels_update ON public.vessels;
CREATE POLICY vessels_select ON public.vessels
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY vessels_insert ON public.vessels
  FOR INSERT TO authenticated WITH CHECK (public.is_staff());
CREATE POLICY vessels_update ON public.vessels
  FOR UPDATE TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

-- ── deal_next_steps ─────────────────────────────────────────
ALTER TABLE public.deal_next_steps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth users can manage next steps" ON public.deal_next_steps;
DROP POLICY IF EXISTS deal_next_steps_staff_all ON public.deal_next_steps;
CREATE POLICY deal_next_steps_staff_all ON public.deal_next_steps
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

-- ── downtime_logs ───────────────────────────────────────────
ALTER TABLE public.downtime_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Authenticated users can insert downtime_logs" ON public.downtime_logs;
DROP POLICY IF EXISTS "Authenticated users can read downtime_logs"   ON public.downtime_logs;
DROP POLICY IF EXISTS downtime_logs_staff_select ON public.downtime_logs;
DROP POLICY IF EXISTS downtime_logs_staff_insert ON public.downtime_logs;
CREATE POLICY downtime_logs_staff_select ON public.downtime_logs
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY downtime_logs_staff_insert ON public.downtime_logs
  FOR INSERT TO authenticated WITH CHECK (public.is_staff());

-- ── peat_documents / peat_chunks ────────────────────────────
-- Drop the wide "any authenticated can read" policies. The existing
-- "Staff can manage ..." (role <> 'client') FOR ALL policies already
-- give staff read+write; clients/anon get nothing.
ALTER TABLE public.peat_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.peat_chunks    ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Staff can read peat_documents" ON public.peat_documents;
DROP POLICY IF EXISTS "Staff can read peat_chunks"    ON public.peat_chunks;

-- ── redundant duplicate policies (no access change) ─────────
DROP POLICY IF EXISTS staff_all_clients ON public.clients;
DROP POLICY IF EXISTS "Admins can read all hr_profiles" ON public.hr_profiles;
