-- ============================================================
-- Shipper tables — close cross-tenant "authenticated full access"
-- (audit follow-up: missed by portal_rls_wide_open_lockdown.sql).
--
-- shipper_keylines and shipper_pallet_plans each carried a single
-- permissive policy:
--     CREATE POLICY "authenticated full access" ... USING (true) WITH CHECK (true)
-- so ANY logged-in user — including a client-portal JWT — could
-- read/insert/update/delete every brand's shipper keyline and pallet
-- plan data (packaging IP). Supabase's own linter flags both as
-- rls_policy_always_true.
--
-- Fix: drop the open policy and replace with staff_all (is_staff()),
-- exactly like the other staff-only tables. The Shipper & Pallet
-- Planner is a staff-only Tools screen (not in the client portal nav),
-- and is_staff() returns true for every non-client role, so this
-- preserves current staff behaviour while removing client/anon reach.
--
-- The embedded "set up table" SQL in index.html (KEYLINE_SQL /
-- PALLET_SQL) is updated in the same change to emit staff_all, so a
-- staff re-running setup cannot re-introduce the open policy.
--
-- Idempotent / safe to re-run. is_staff() is defined + hardened in
-- fix_is_staff_and_app_users_insert.sql.
-- ============================================================

-- ── shipper_keylines ────────────────────────────────────────
ALTER TABLE public.shipper_keylines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated full access" ON public.shipper_keylines;
DROP POLICY IF EXISTS staff_all ON public.shipper_keylines;
CREATE POLICY staff_all ON public.shipper_keylines
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

-- ── shipper_pallet_plans ────────────────────────────────────
ALTER TABLE public.shipper_pallet_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated full access" ON public.shipper_pallet_plans;
DROP POLICY IF EXISTS staff_all ON public.shipper_pallet_plans;
CREATE POLICY staff_all ON public.shipper_pallet_plans
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
