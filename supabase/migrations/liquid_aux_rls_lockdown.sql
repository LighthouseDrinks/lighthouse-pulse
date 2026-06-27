-- ============================================================
-- Lock down the remaining liquid-area tables to staff-only.
--
-- Same problem as liquid_history: these tables carried wide-open
-- policies (USING(true) WITH CHECK(true), or anon SELECT) plus
-- UPDATE/DELETE/TRUNCATE grants for anon + authenticated, so the
-- 3 portal `client` users (and anon) could read/forge/wipe them.
-- TRUNCATE bypasses RLS, so the grant itself is a wipe risk.
--
-- Verified safe before writing:
--   - The client portal (index.html lines ~2153-5129) never reads
--     job_liquid_signoff, vessel_history, or liquid_transfers*.
--     All access is staff UI (job close-out, scheduling, vessel
--     register, transfer save).
--   - is_staff() = app role <> 'client' and fails OPEN on null role,
--     so staff cannot be locked out.
--
-- Per-table treatment (matches actual app usage):
--   * job_liquid_signoff      -> staff ALL (app SELECTs/INSERTs/UPDATEs)
--   * liquid_transfers + src + dest -> keep existing staff_all_* ALL
--     policy, just drop the redundant wide-open one
--   * vessel_history          -> staff append-only (app only INSERT/SELECT)
--
-- ROLLBACK (restores prior wide-open behaviour):
--   CREATE POLICY authenticated_full_access ON public.job_liquid_signoff
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   CREATE POLICY authenticated_full_access ON public.liquid_transfers
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   CREATE POLICY authenticated_full_access ON public.liquid_transfer_sources
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   CREATE POLICY authenticated_full_access ON public.liquid_transfer_destinations
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   CREATE POLICY vessel_history_auth_all ON public.vessel_history
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   CREATE POLICY vessel_history_anon_select ON public.vessel_history
--     FOR SELECT TO anon USING (true);
--   -- plus: GRANT UPDATE, DELETE ON <table> TO authenticated; as needed.
--
-- Safe to re-run.
-- ============================================================

-- ── job_liquid_signoff: staff full access ───────────────────
ALTER TABLE public.job_liquid_signoff ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_all_liquid_signoff ON public.job_liquid_signoff;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_liquid_signoff;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public'
       AND tablename='job_liquid_signoff' AND policyname='staff_all_signoff'
  ) THEN
    CREATE POLICY "staff_all_signoff" ON public.job_liquid_signoff
      FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
  END IF;
END
$$;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.job_liquid_signoff FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON public.job_liquid_signoff FROM authenticated;

-- ── liquid_transfers (+ sources + destinations): drop redundant ──
-- wide-open policy; the existing staff_all_* (ALL, is_staff()) remains.
ALTER TABLE public.liquid_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.liquid_transfer_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.liquid_transfer_destinations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_full_access ON public.liquid_transfers;
DROP POLICY IF EXISTS authenticated_full_access ON public.liquid_transfer_sources;
DROP POLICY IF EXISTS authenticated_full_access ON public.liquid_transfer_destinations;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfers FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfer_sources FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfer_destinations FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfers FROM authenticated;
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfer_sources FROM authenticated;
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_transfer_destinations FROM authenticated;

-- ── vessel_history: staff append-only ───────────────────────
ALTER TABLE public.vessel_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vessel_history_anon_select ON public.vessel_history;
DROP POLICY IF EXISTS vessel_history_auth_all ON public.vessel_history;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public'
       AND tablename='vessel_history' AND policyname='vessel_history_staff_select'
  ) THEN
    CREATE POLICY "vessel_history_staff_select" ON public.vessel_history
      FOR SELECT TO authenticated USING (public.is_staff());
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public'
       AND tablename='vessel_history' AND policyname='vessel_history_staff_insert'
  ) THEN
    CREATE POLICY "vessel_history_staff_insert" ON public.vessel_history
      FOR INSERT TO authenticated WITH CHECK (public.is_staff());
  END IF;
END
$$;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.vessel_history FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.vessel_history FROM authenticated;
