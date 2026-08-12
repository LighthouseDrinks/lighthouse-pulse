-- ============================================================
-- Reduce the anon-callable SECURITY DEFINER RPC surface
-- (advisor 0028/0029 anon/authenticated_security_definer_function_executable).
--
-- Postgres requires the CALLING role to hold EXECUTE on any function
-- referenced by an RLS policy — verified empirically: revoking EXECUTE
-- from authenticated on a policy predicate makes the whole query fail
-- with "permission denied for function". Therefore we CANNOT revoke
-- EXECUTE from `authenticated` on the RLS helper predicates
-- (is_staff, is_admin, ...) without breaking RLS across the app.
--
-- So we split the flagged functions into three groups:
--
--   A. Trigger / event-trigger functions — never legitimately called
--      via /rest/v1/rpc and never used as policy predicates. Triggers
--      fire regardless of the caller's EXECUTE privilege, so we revoke
--      from PUBLIC + anon + authenticated entirely.
--
--   B. Legitimate authenticated RPCs (called by the app) — keep
--      authenticated, drop anon + PUBLIC.
--
--   C. RLS helper predicates (used inside policies) — MUST stay
--      executable by authenticated for RLS to work; drop anon +
--      PUBLIC only. The advisor's 0029 (authenticated) warning for
--      these is expected and accepted.
--
-- Deliberately NOT touched (anon-callable by design — public tokenized
-- approval links, each gated on a uuid token):
--   get_bom_approval, submit_bom_approval,
--   get_label_approval, submit_label_approval
--
-- ROLLBACK: GRANT EXECUTE ON FUNCTION <sig> TO anon (and PUBLIC).
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── Group A: trigger + event-trigger functions (full revoke) ─
REVOKE EXECUTE ON FUNCTION public.app_users_validate_self_insert()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clients_client_update_guard()         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clock_events_dedupe()                 FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clock_events_log_audit()              FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clock_events_set_edit_meta()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clock_events_transition_shadow()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_meeting_action_done_from_task()  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()                     FROM PUBLIC, anon, authenticated;

-- ── Group B: legitimate authenticated RPCs (drop anon/PUBLIC) ─
REVOKE EXECUTE ON FUNCTION public.clock_event_insert(text, boolean)     FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.clock_event_insert(text, boolean)     TO authenticated;
REVOKE EXECUTE ON FUNCTION public.meeting_pull_open_actions(uuid)       FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.meeting_pull_open_actions(uuid)       TO authenticated;

-- ── Group C: RLS helper predicates (keep authenticated) ──────
REVOKE EXECUTE ON FUNCTION public.is_staff()                    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_staff()                    TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_admin()                    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_admin()                    TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_client_user()              FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_client_user()              TO authenticated;
REVOKE EXECUTE ON FUNCTION public.current_app_user_role()       FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.current_app_user_role()       TO authenticated;
REVOKE EXECUTE ON FUNCTION public.current_app_user_client_id()  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.current_app_user_client_id()  TO authenticated;
REVOKE EXECUTE ON FUNCTION public.current_client_id()           FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.current_client_id()           TO authenticated;
REVOKE EXECUTE ON FUNCTION public.mh_is_admin()                 FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mh_is_admin()                 TO authenticated;
REVOKE EXECUTE ON FUNCTION public.mh_is_attendee(uuid)          FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mh_is_attendee(uuid)          TO authenticated;
