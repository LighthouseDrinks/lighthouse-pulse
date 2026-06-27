-- ============================================================
-- Magic-link approvals — token-scoped anon access (Phase 2, finding C-6).
--
-- The public approval pages previously read/updated job_bom_approvals and
-- job_label_approvals via direct PostgREST with anon policies of USING
-- (true), so any anonymous caller could list/modify EVERY approval row,
-- not just the one whose token they hold.
--
-- This replaces direct anon table access with SECURITY DEFINER RPCs that
-- only ever touch the single row matching the supplied approval_token
-- (a unguessable uuid that acts as the bearer credential). Direct anon
-- table privileges are revoked, and the legacy anon policies are dropped.
-- Staff continue to use the tables directly via their staff_all policy.
--
-- The functions RETURN SETOF the table so PostgREST returns a JSON array,
-- matching the existing client code (rows[0] / updated[0]). Decision
-- values are constrained so the RPC can't be used to write arbitrary data.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── BOM approval ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_bom_approval(p_token uuid)
  RETURNS SETOF public.job_bom_approvals
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT * FROM public.job_bom_approvals WHERE approval_token = p_token LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.submit_bom_approval(
  p_token uuid, p_decision text, p_name text, p_notes text, p_user_agent text)
  RETURNS SETOF public.job_bom_approvals
  LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public'
AS $$
  UPDATE public.job_bom_approvals
     SET client_decision      = p_decision,
         client_decided_at    = now(),
         client_approver_name = p_name,
         client_notes         = p_notes,
         client_user_agent    = p_user_agent
   WHERE approval_token = p_token
     AND p_decision IN ('approved', 'flagged')
  RETURNING *;
$$;

-- ── Label approval ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_label_approval(p_token uuid)
  RETURNS SETOF public.job_label_approvals
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT * FROM public.job_label_approvals WHERE approval_token = p_token LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.submit_label_approval(
  p_token uuid, p_decision text, p_name text, p_notes text, p_user_agent text)
  RETURNS SETOF public.job_label_approvals
  LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path TO 'public'
AS $$
  UPDATE public.job_label_approvals
     SET client_decision      = p_decision,
         client_decided_at    = now(),
         client_approver_name = p_name,
         client_notes         = p_notes,
         client_user_agent    = p_user_agent
   WHERE approval_token = p_token
     AND p_decision IN ('approved', 'rejected')
  RETURNING *;
$$;

-- ── Grants: anon may only call the token-scoped RPCs ─────────
GRANT EXECUTE ON FUNCTION public.get_bom_approval(uuid)                              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_bom_approval(uuid, text, text, text, text)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_label_approval(uuid)                            TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_label_approval(uuid, text, text, text, text) TO anon, authenticated;

-- ── Remove direct anon table access ─────────────────────────
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.job_bom_approvals   FROM anon;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.job_label_approvals FROM anon;

DROP POLICY IF EXISTS job_bom_approvals_anon_select ON public.job_bom_approvals;
DROP POLICY IF EXISTS job_bom_approvals_anon_update ON public.job_bom_approvals;
DROP POLICY IF EXISTS anon_token_read   ON public.job_label_approvals;
DROP POLICY IF EXISTS anon_token_update ON public.job_label_approvals;
