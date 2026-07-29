-- ============================================================
-- Version-control the RLS helper functions (audit: functions existed
-- only in the live DB, not in migrations -> drift risk).
--
-- These are the tenant-boundary helpers every portal RLS policy relies
-- on. Definitions below are byte-for-byte the live ones (captured via
-- pg_get_functiondef), committed here so the boundary is reproducible
-- and cannot silently drift. is_staff() is already version-controlled in
-- fix_is_staff_and_app_users_insert.sql.
--
-- All are STABLE SECURITY DEFINER with a locked search_path, and read
-- app_users as the definer so policies can resolve the caller's
-- role / client_id.
--
-- Idempotent / safe to re-run (CREATE OR REPLACE preserves ownership).
-- ============================================================

CREATE OR REPLACE FUNCTION public.current_app_user_role()
  RETURNS text
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  select role from app_users where auth_user_id = auth.uid() limit 1;
$function$;

CREATE OR REPLACE FUNCTION public.current_app_user_client_id()
  RETURNS text
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  select client_id::text from app_users where auth_user_id = auth.uid() limit 1;
$function$;

CREATE OR REPLACE FUNCTION public.is_client_user()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  select public.current_app_user_role() = 'client';
$function$;
