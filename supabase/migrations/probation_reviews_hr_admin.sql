-- Let HR admins (Human Resources, Production Manager, and the
-- existing MD / Ops Dir / BA set) write probation reviews, matching
-- who can already manage Employee Details.
--
-- Idempotent / safe to re-run.

CREATE OR REPLACE FUNCTION public.is_probation_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT public.is_hr_admin()
      OR EXISTS (
        SELECT 1
        FROM public.app_users au
        WHERE au.auth_user_id = auth.uid()
          AND au.role IN ('managing_director', 'operations_director', 'business_analyst', 'human_resources')
      );
$function$;
