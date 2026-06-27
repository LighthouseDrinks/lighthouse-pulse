-- ============================================================
-- liquid_history: lock down the audit log (staff-only, append-only).
--
-- Problem: liquid_history had a single wide-open policy
--   authenticated_full_access  USING(true) WITH CHECK(true)
-- meaning ANY logged-in user - including the 3 portal `client`
-- users - could INSERT fake audit rows, UPDATE, or DELETE history.
-- On top of that, anon + authenticated held UPDATE/DELETE/TRUNCATE
-- table grants. TRUNCATE in particular bypasses RLS entirely, so the
-- grant alone let an authenticated client wipe the whole audit log.
--
-- This migration makes the audit trail tamper-resistant:
--   * SELECT  -> staff only (is_staff(): app role <> 'client')
--   * INSERT  -> staff only
--   * UPDATE / DELETE -> no policy = denied for anon + authenticated
--   * Revoke UPDATE/DELETE/TRUNCATE (+ INSERT for anon) grants so the
--     append-only guarantee holds even outside RLS (TRUNCATE).
-- service_role / postgres keep full access for backend corrections.
--
-- Verified safe before writing:
--   - The app only ever INSERTs liquid_history (no UPDATE/DELETE in code).
--   - All liquid_history reads are staff UI (reconciliation, container
--     detail, blending, job detail) - the client portal never reads it.
--   - All 7 liquid-operating roles are non-'client'; only 3 users are
--     'client'. is_staff() fails OPEN on null/unknown role, so staff
--     cannot be accidentally locked out.
--
-- ROLLBACK (if ever needed - restores prior behaviour):
--   DROP POLICY IF EXISTS liquid_history_staff_select ON public.liquid_history;
--   DROP POLICY IF EXISTS liquid_history_staff_insert ON public.liquid_history;
--   CREATE POLICY authenticated_full_access ON public.liquid_history
--     FOR ALL TO authenticated USING (true) WITH CHECK (true);
--   GRANT INSERT, UPDATE, DELETE ON public.liquid_history TO authenticated;
--
-- Safe to re-run: policy creates are guarded; DROP/REVOKE use IF EXISTS
-- semantics and are idempotent.
-- ============================================================

ALTER TABLE public.liquid_history ENABLE ROW LEVEL SECURITY;

-- 1. Remove the wide-open policy.
DROP POLICY IF EXISTS authenticated_full_access ON public.liquid_history;

-- 2. Staff-only read + insert (CREATE POLICY has no IF NOT EXISTS).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname='public' AND tablename='liquid_history'
       AND policyname='liquid_history_staff_select'
  ) THEN
    CREATE POLICY "liquid_history_staff_select" ON public.liquid_history
      FOR SELECT TO authenticated USING (public.is_staff());
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname='public' AND tablename='liquid_history'
       AND policyname='liquid_history_staff_insert'
  ) THEN
    CREATE POLICY "liquid_history_staff_insert" ON public.liquid_history
      FOR INSERT TO authenticated WITH CHECK (public.is_staff());
  END IF;
END
$$;

-- 3. Append-only at the grant level. authenticated keeps SELECT + INSERT
--    (both gated to staff by the policies above); everything destructive
--    is revoked. anon loses write entirely. TRUNCATE is the critical one
--    because it ignores RLS.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_history FROM anon;
REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.liquid_history FROM authenticated;
