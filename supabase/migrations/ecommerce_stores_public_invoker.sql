-- ============================================================
-- ecommerce_stores_public — re-assert security_invoker (advisor
-- ERROR security_definer_view, live state).
--
-- definer_views_security_invoker.sql already flipped this view to
-- security_invoker. A LATER migration (ecommerce_3pl_stores_and_po.sql)
-- redefined the view to add three_pl_client_id and set
-- `security_invoker = off` again, so on the live DB the view is once
-- more SECURITY DEFINER: it runs as the owner and BYPASSES the
-- caller's RLS. Because authenticated holds SELECT on the view, any
-- client-portal JWT can currently read EVERY active store row
-- (revenue_synced, store_url, Xero account codes) regardless of RLS.
--
-- Fix: flip back to security_invoker so the view inherits the CALLER's
-- RLS on the base table (ecommerce_stores), and revoke anon.
--
--   * ecommerce_stores already has a staff-only SELECT policy
--     (ecommerce_stores_staff_select). With the invoker view, staff
--     keep seeing rows; clients/anon get none.
--   * A security_invoker view checks the CALLER's column privileges
--     on the base table. The live per-column grant to authenticated
--     is missing three_pl_client_id (added by the 3pl migration), so
--     without this grant staff would hit "permission denied for
--     column three_pl_client_id". We re-grant the full non-secret
--     column list the view exposes. api_key / api_secret are
--     deliberately NOT granted, so credentials stay unreadable even
--     to staff via a direct base-table query.
--
-- Only staff finance/e-commerce screens read this view
-- (index.html:64296 / 65189 / 65414); the client portal never does.
--
-- ROLLBACK: ALTER VIEW ... SET (security_invoker = off) and
-- GRANT SELECT ON public.ecommerce_stores_public TO anon.
--
-- Idempotent / safe to re-run.
-- ============================================================

ALTER TABLE public.ecommerce_stores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ecommerce_stores_staff_select ON public.ecommerce_stores;
CREATE POLICY ecommerce_stores_staff_select ON public.ecommerce_stores
  FOR SELECT TO authenticated USING (public.is_staff());

-- Non-secret columns the public view exposes (no api_key / api_secret).
-- Matches the view's SELECT list exactly, including three_pl_client_id.
GRANT SELECT (id, name, platform, store_url, is_active, created_at,
              created_by, updated_at, connection_status, last_synced_at,
              orders_synced_count, revenue_synced, error_message,
              sync_from_date, xero_sales_account, xero_shipping_account,
              three_pl_client_id)
  ON public.ecommerce_stores TO authenticated;

ALTER VIEW IF EXISTS public.ecommerce_stores_public SET (security_invoker = on);
REVOKE ALL  ON public.ecommerce_stores_public FROM anon;
GRANT SELECT ON public.ecommerce_stores_public TO authenticated;
