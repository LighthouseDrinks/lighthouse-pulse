-- ============================================================
-- SECURITY DEFINER view lockdown, round 2 (audit C-1b + advisor ERROR
-- security_definer_view on 4 views).
--
-- line_throughput_live, line_hourly_totals, xero_connection_public and
-- ecommerce_stores_public were all SECURITY DEFINER (they ran as the
-- view owner and BYPASSED the caller's RLS) and granted SELECT to anon +
-- authenticated. That let any client-portal JWT — and an anonymous
-- holder of the publishable key — read production telemetry and Xero /
-- e-commerce integration metadata.
--
-- Fix: flip all four to security_invoker so they inherit the CALLER's
-- RLS, and revoke anon.
--
--   * line_* views read public.line_events, which is now staff-only
--     (line_events_client_lockdown.sql). authenticated already holds a
--     table SELECT grant, so staff (incl. the TV kiosk staff session)
--     keep seeing rows; clients/anon get none.
--
--   * xero_connection / ecommerce_stores base tables had RLS enabled
--     with NO policy and NO grant to authenticated. An invoker view
--     would therefore "permission denied" for staff. We add a staff-only
--     SELECT policy AND a COLUMN-SCOPED SELECT grant covering only the
--     non-secret columns the public views expose — so the views work for
--     staff, clients get 0 rows, and credential columns (access/refresh
--     tokens, API secrets) stay unreadable even to staff via a direct
--     query. Service-role writes (xero-oauth / ecommerce-sync) are
--     unaffected.
--
-- Only staff finance screens read these views (index.html:59120/59189/
-- 59823/62068); the client portal never does.
--
-- ROLLBACK: SET security_invoker = off on each view and re-GRANT SELECT
-- to anon.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── line throughput views (base: line_events, already staff-scoped) ──
ALTER VIEW IF EXISTS public.line_throughput_live SET (security_invoker = on);
ALTER VIEW IF EXISTS public.line_hourly_totals   SET (security_invoker = on);
REVOKE ALL ON public.line_throughput_live FROM anon, authenticated;
REVOKE ALL ON public.line_hourly_totals   FROM anon, authenticated;
GRANT SELECT ON public.line_throughput_live TO authenticated;
GRANT SELECT ON public.line_hourly_totals   TO authenticated;

-- ── xero_connection_public (base: xero_connection) ──────────
ALTER TABLE public.xero_connection ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS xero_connection_staff_select ON public.xero_connection;
CREATE POLICY xero_connection_staff_select ON public.xero_connection
  FOR SELECT TO authenticated USING (public.is_staff());
-- Only the columns the public view exposes (no access_token/refresh_token).
GRANT SELECT (id, tenant_id, tenant_name, connected_by, connected_at,
              disconnected_at, is_active, token_expiry, updated_at)
  ON public.xero_connection TO authenticated;
ALTER VIEW IF EXISTS public.xero_connection_public SET (security_invoker = on);
REVOKE ALL ON public.xero_connection_public FROM anon, authenticated;
GRANT SELECT ON public.xero_connection_public TO authenticated;

-- ── ecommerce_stores_public (base: ecommerce_stores) ────────
ALTER TABLE public.ecommerce_stores ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ecommerce_stores_staff_select ON public.ecommerce_stores;
CREATE POLICY ecommerce_stores_staff_select ON public.ecommerce_stores
  FOR SELECT TO authenticated USING (public.is_staff());
-- Only the non-secret columns the public view exposes (no api keys/tokens).
GRANT SELECT (id, name, platform, store_url, is_active, created_at,
              created_by, updated_at, connection_status, last_synced_at,
              orders_synced_count, revenue_synced, error_message,
              sync_from_date, xero_sales_account, xero_shipping_account)
  ON public.ecommerce_stores TO authenticated;
ALTER VIEW IF EXISTS public.ecommerce_stores_public SET (security_invoker = on);
REVOKE ALL ON public.ecommerce_stores_public FROM anon, authenticated;
GRANT SELECT ON public.ecommerce_stores_public TO authenticated;
