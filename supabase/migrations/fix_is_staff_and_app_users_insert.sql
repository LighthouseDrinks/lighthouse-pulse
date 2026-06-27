-- ============================================================
-- Registration privilege-escalation fix (Phase 1, finding C-2).
--
-- THREE problems combined into an admin-takeover hole:
--   1. is_staff() = coalesce(role,'') <> 'client' returns TRUE for a
--      brand-new auth user that has no app_users row yet (NULL role).
--   2. app_users INSERT policy required only is_staff() in WITH CHECK,
--      so that brand-new user could insert their OWN app_users row with
--      ANY role (e.g. 'managing_director').
--   3. Invite tokens are unsigned base64 (btoa(JSON)), and doRegister
--      writes role/client_id straight from the token, so even the
--      client_id could be forged to another brand.
--
-- Fixes:
--   A. is_staff() is NULL-safe: a user with no role is NOT staff.
--   B. Replace app_users_insert_staff with app_users_insert_self that
--      allows real staff inserts OR a self-insert for your own auth uid.
--   C. A SECURITY DEFINER BEFORE-INSERT trigger validates every
--      non-staff self-insert against a staff-created pending_invites row
--      (matching email + role + client_id). The unsigned token is now
--      defense-in-depth only — the server is the authority.
--
-- VERIFIED: 0 app_users rows currently have a NULL role, so hardening
-- is_staff() changes no existing staff access. All current registration
-- flows go through an invite (doRegister requires _INVITE_TOKEN), and
-- staff create a pending_invites row per invite, so the trigger does not
-- block legitimate onboarding.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- A. NULL-safe is_staff() ------------------------------------
CREATE OR REPLACE FUNCTION public.is_staff()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  select public.current_app_user_role() is not null
     and public.current_app_user_role() <> 'client';
$function$;

-- C. Self-insert validation trigger --------------------------
CREATE OR REPLACE FUNCTION public.app_users_validate_self_insert()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_email text;
  v_match integer;
BEGIN
  -- Real staff (existing app_users row with a staff role) may insert
  -- arbitrary rows via the admin UI.
  IF public.is_staff() THEN
    RETURN NEW;
  END IF;

  -- Otherwise this must be a self-insert for the caller's own auth uid.
  IF NEW.auth_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'app_users: you may only create your own profile';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = auth.uid();

  -- Must match a staff-created invite for this email, with the SAME role
  -- and client_id. Forging the token to another role/brand will not match.
  SELECT count(*) INTO v_match
  FROM public.pending_invites pi
  WHERE lower(pi.email) = lower(coalesce(NEW.email, v_email))
    AND coalesce(pi.role, '') = coalesce(NEW.role, '')
    AND pi.client_id IS NOT DISTINCT FROM NEW.client_id;

  IF v_match = 0 THEN
    RAISE EXCEPTION 'app_users: no matching invite for this account (email/role/client mismatch)';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_app_users_validate_self_insert ON public.app_users;
CREATE TRIGGER trg_app_users_validate_self_insert
  BEFORE INSERT ON public.app_users
  FOR EACH ROW EXECUTE FUNCTION public.app_users_validate_self_insert();

-- B. INSERT policy: allow staff, or a self-insert (trigger enforces the
--    invite match for non-staff). ------------------------------------
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS app_users_insert_staff ON public.app_users;
DROP POLICY IF EXISTS app_users_insert_self  ON public.app_users;
CREATE POLICY app_users_insert_self ON public.app_users
  FOR INSERT TO authenticated
  WITH CHECK (public.is_staff() OR auth_user_id = auth.uid());
