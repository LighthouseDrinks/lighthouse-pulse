-- ============================================================
-- Pin search_path on functions flagged by the Supabase linter
-- (function_search_path_mutable). A mutable search_path on a
-- SECURITY DEFINER function is a privilege-escalation vector.
--
-- We use ALTER FUNCTION ... SET search_path (not CREATE OR REPLACE) so
-- the function bodies are untouched -> zero behaviour change. Signatures
-- are resolved automatically via regprocedure, so overloaded functions
-- (e.g. match_peat_chunks) are handled correctly.
--
-- current_client_id() is legacy/dead (no policy references it) but is
-- left in place per legacy_client_users_policy_cleanup.sql; we only
-- harden its search_path rather than dropping it.
--
-- Idempotent / safe to re-run.
-- ============================================================

DO $mig$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'current_client_id', 'is_admin', 'set_batch_defaults',
        'log_batch_creation', 'match_peat_chunks', 'roles_set_updated_at',
        'xero_do_connect', 'xero_do_refresh'
      )
  LOOP
    EXECUTE 'ALTER FUNCTION ' || r.sig::text || ' SET search_path TO ''public''';
  END LOOP;
END
$mig$;
