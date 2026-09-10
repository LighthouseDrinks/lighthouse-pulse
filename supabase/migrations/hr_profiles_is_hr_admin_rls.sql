-- ============================================================
-- hr_profiles admin access: use roles.is_hr_admin
--
-- After portal_rls_tenant_lockdown dropped authenticated_full_access,
-- "Admins can manage all hr_profiles" was left with a hardcoded role
-- list (managing_director, operations_director, business_analyst).
-- The Human Resources role has is_hr_admin + hr_view_all in the UI
-- but could not read other employees' hr_profiles, so Pulse painted
-- empty Personal / Employment / Pay / Bank / Emergency fields.
--
-- Own-row policies are unchanged. Clients stay blocked.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_hr_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_users au
    JOIN public.roles r ON r.key = au.role
    WHERE au.auth_user_id = auth.uid()
      AND r.is_hr_admin IS TRUE
  );
$function$;

REVOKE EXECUTE ON FUNCTION public.is_hr_admin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_hr_admin() TO authenticated;

ALTER TABLE public.hr_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can manage all hr_profiles" ON public.hr_profiles;
CREATE POLICY "Admins can manage all hr_profiles" ON public.hr_profiles
  FOR ALL TO authenticated
  USING      (public.is_hr_admin())
  WITH CHECK (public.is_hr_admin());
