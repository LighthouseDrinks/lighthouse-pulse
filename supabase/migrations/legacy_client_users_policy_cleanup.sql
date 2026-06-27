-- ============================================================
-- Remove dead legacy RLS policies that key off current_client_id()
-- (Phase 3 cleanup).
--
-- current_client_id() reads from client_users, which is EMPTY (0 rows)
-- and unused — portal users live in app_users. Every policy below
-- therefore evaluates client_id = NULL and grants nothing, so they are
-- pure dead weight that obscures the real boundary (the current_app_user_*
-- policies). This drops them. The current_client_id() function itself is
-- left in place (harmless once unreferenced) to avoid dependency churn.
--
-- Idempotent / safe to re-run. Several of these are also dropped in
-- portal_rls_tenant_lockdown.sql; DROP ... IF EXISTS makes the overlap a
-- no-op regardless of apply order.
-- ============================================================

DROP POLICY IF EXISTS client_own_blend_calcs  ON public.blend_calculations;
DROP POLICY IF EXISTS client_own_bom_items    ON public.bom_items;
DROP POLICY IF EXISTS client_insert_boms      ON public.boms;
DROP POLICY IF EXISTS client_own_boms         ON public.boms;
DROP POLICY IF EXISTS client_see_own          ON public.clients;
DROP POLICY IF EXISTS client_own_deliveries   ON public.dry_goods_deliveries;
DROP POLICY IF EXISTS client_insert_notifs    ON public.goods_in_notifications;
DROP POLICY IF EXISTS client_own_notifications ON public.goods_in_notifications;
DROP POLICY IF EXISTS client_insert_jobs      ON public.jobs;
DROP POLICY IF EXISTS client_own_jobs         ON public.jobs;
DROP POLICY IF EXISTS client_own_containers   ON public.liquid_containers;
