-- ============================================================
-- Miscellaneous security hardening (remaining advisor WARN/INFO).
--
-- 1. Pin search_path on the two functions still flagged by the linter
--    (function_search_path_mutable): _search_age_band(integer) and
--    _search_profile_matches(jsonb, jsonb). ALTER (not CREATE OR
--    REPLACE) so the bodies are untouched — zero behaviour change.
--    Mirrors function_search_path_hardening.sql.
--
-- 2. Move pg_net out of the public schema (extension_in_public).
--    pg_net is currently unused (created in clock_events_guard.sql but
--    never called — no webhook triggers, no net.http_* callers, checked
--    live). The build on this instance is NON-relocatable (ALTER ...
--    SET SCHEMA fails — verified), so we fall back to DROP + CREATE
--    ... SCHEMA extensions, guarded by a dependents check and wrapped
--    so any failure rolls back to the status quo instead of hard-
--    failing the migration. Note pg_net's actual objects always live
--    in the dedicated `net` schema; only the extension registration
--    moves.
--
-- 3. Document the intent of the 5 fail-closed tables (RLS enabled, no
--    policy => deny-all to anon/authenticated; service_role only).
--    Advisor INFO rls_enabled_no_policy — this is intentional, not a
--    gap: these are unbuilt/feature-pending tables (0 rows) reachable
--    only via service-role edge functions.
--
-- NOTE on xero_connection (checked, no change needed): access_token /
-- refresh_token are NOT column-granted to anon or authenticated, so the
-- OAuth tokens the xero-oauth function stores there are unreadable via
-- PostgREST even for staff. Row access is already is_staff()-gated
-- (xero_connection_staff_select) on non-secret columns only.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── 1. Pin search_path on the two remaining flagged functions ─
DO $mig$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('_search_age_band', '_search_profile_matches')
  LOOP
    EXECUTE 'ALTER FUNCTION ' || r.sig::text || ' SET search_path TO ''public''';
  END LOOP;
END
$mig$;

-- ── 2. Relocate pg_net out of public (best-effort) ───────────
DO $mig$
DECLARE
  v_dependents int;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_net' AND n.nspname = 'public'
  ) THEN
    CREATE SCHEMA IF NOT EXISTS extensions;
    BEGIN
      ALTER EXTENSION pg_net SET SCHEMA extensions;
    EXCEPTION WHEN OTHERS THEN
      -- Non-relocatable build: re-register under `extensions` instead,
      -- but only if nothing outside the extension depends on it.
      SELECT count(*) INTO v_dependents
      FROM pg_depend d
      WHERE d.refclassid = 'pg_extension'::regclass
        AND d.refobjid   = (SELECT oid FROM pg_extension WHERE extname = 'pg_net')
        AND d.deptype    = 'n';
      IF v_dependents = 0 THEN
        BEGIN
          DROP EXTENSION pg_net;
          CREATE EXTENSION pg_net SCHEMA extensions;
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'pg_net could not be relocated (%); leaving in public.', SQLERRM;
        END;
      ELSE
        RAISE NOTICE 'pg_net has % dependent object(s); leaving in public.', v_dependents;
      END IF;
    END;
  END IF;
END
$mig$;

-- ── 3. Document intentional fail-closed (deny-all) tables ────
COMMENT ON TABLE public.samples           IS 'RLS enabled, no policy: intentional deny-all (service_role only). Feature pending.';
COMMENT ON TABLE public.sample_components IS 'RLS enabled, no policy: intentional deny-all (service_role only). Feature pending.';
COMMENT ON TABLE public.stock_movements   IS 'RLS enabled, no policy: intentional deny-all (service_role only). Feature pending.';
COMMENT ON TABLE public.job_waste         IS 'RLS enabled, no policy: intentional deny-all (service_role only). Feature pending.';
COMMENT ON TABLE public.dry_goods_locations IS 'RLS enabled, no policy: intentional deny-all (service_role only). Feature pending.';
