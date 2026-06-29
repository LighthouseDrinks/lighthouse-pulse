-- ============================================================
-- Wide-open table lockdown — block client portal cross-tenant reach
-- (audit finding: CRITICAL cross-tenant exposure).
--
-- The client portal authenticates a Supabase user (role = 'client') and
-- reads/writes via PostgREST with that user's JWT, so RLS is the only
-- tenant boundary. The portal UI itself only queries tenant-scoped
-- tables, BUT the client's `authenticated` JWT can hit ANY PostgREST
-- endpoint. The tables below still carried "any authenticated user"
-- policies — either:
--     * authenticated_full_access / *_auth_all : USING (true)
--     * *_all / read / insert / update          : TO public,
--                                                   auth.role() = 'authenticated'
-- so a logged-in client could SELECT/INSERT/UPDATE/DELETE every brand's
-- recipe IP (bom_items, blends*), production data (bottling_runs*,
-- job_components, dry_goods_usage), finance (job_invoice_lines,
-- credit_control_*), ecommerce, and staff PII (staff, leave_requests,
-- roster_shifts, suppliers, ...).
--
-- Fix: drop the over-broad permissive policies and guarantee a
-- staff-only path via staff_all (public.is_staff()). is_staff() returns
-- true for every NON-client role, so this PRESERVES the prior
-- "all staff, full access" behaviour exactly while removing client and
-- role-less access. The portal reads NONE of these tables (verified
-- against the portal data layer, index.html:2196-5300), so no client UI
-- breaks. Existing narrower staff/admin/own-row policies are left in
-- place (harmless — permissive policies OR together).
--
-- NOT touched here (deliberate):
--   * clock_events / timecard_requests — only an UPDATE WITH CHECK (true)
--     was flagged; the USING clauses are already permission-scoped and
--     these feed the kiosk clock-in flow. Out of scope for the portal
--     leak; handle separately if desired.
--
-- Idempotent / safe to re-run. is_staff() is defined + hardened in
-- fix_is_staff_and_app_users_insert.sql.
-- ============================================================

-- Helper: (re)create the staff_all policy for a table, dropping first so
-- the migration is idempotent. CREATE POLICY has no IF NOT EXISTS.
DO $mig$
DECLARE
  t text;
  staff_only text[] := ARRAY[
    'audit_log','blend_calculations','blend_components','blends','bom_items',
    'bottling_run_depletions','bottling_runs','client_users','credit_control_log',
    'credit_control_templates','dry_goods_skus_history','dry_goods_usage',
    'ecommerce_order_items','ecommerce_orders','ecommerce_sync_queue',
    'geofence_settings','goods_in_notifications','job_audit_log','job_components',
    'job_drygoods_prep','job_drygoods_prep_items','job_invoice_lines',
    'job_quality_checks','job_weights_measures','leave_requests','roster_shifts',
    'shift_templates','staff','stock_value_log','suppliers','tasks','xero_mappings'
  ];
BEGIN
  FOREACH t IN ARRAY staff_only LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS staff_all ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY staff_all ON public.%I FOR ALL TO authenticated '
      'USING (public.is_staff()) WITH CHECK (public.is_staff())', t);
  END LOOP;
END
$mig$;

-- ── Drop the over-broad permissive policies, table by table ──────────
-- (Names taken from live pg_policies; DROP ... IF EXISTS is a no-op when
--  a name is absent, so re-running or partial prior state is safe.)

-- authenticated_full_access (USING true) on TO authenticated:
DROP POLICY IF EXISTS authenticated_full_access ON public.audit_log;
DROP POLICY IF EXISTS authenticated_full_access ON public.blend_calculations;
DROP POLICY IF EXISTS authenticated_full_access ON public.blend_components;
DROP POLICY IF EXISTS authenticated_full_access ON public.blends;
DROP POLICY IF EXISTS authenticated_full_access ON public.bom_items;
DROP POLICY IF EXISTS authenticated_full_access ON public.bottling_run_depletions;
DROP POLICY IF EXISTS authenticated_full_access ON public.bottling_runs;
DROP POLICY IF EXISTS authenticated_full_access ON public.client_users;
DROP POLICY IF EXISTS authenticated_full_access ON public.dry_goods_usage;
DROP POLICY IF EXISTS authenticated_full_access ON public.geofence_settings;
DROP POLICY IF EXISTS authenticated_full_access ON public.goods_in_notifications;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_audit_log;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_components;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_drygoods_prep;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_drygoods_prep_items;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_quality_checks;
DROP POLICY IF EXISTS authenticated_full_access ON public.job_weights_measures;
DROP POLICY IF EXISTS authenticated_full_access ON public.leave_requests;
DROP POLICY IF EXISTS authenticated_full_access ON public.roster_shifts;
DROP POLICY IF EXISTS authenticated_full_access ON public.staff;
DROP POLICY IF EXISTS authenticated_full_access ON public.suppliers;
DROP POLICY IF EXISTS authenticated_full_access ON public.tasks;

-- *_auth_all / *_authenticated_full_access (USING true) variants:
DROP POLICY IF EXISTS credit_control_log_auth_all          ON public.credit_control_log;
DROP POLICY IF EXISTS credit_control_templates_auth_all    ON public.credit_control_templates;
DROP POLICY IF EXISTS dry_goods_skus_history_auth_all       ON public.dry_goods_skus_history;
DROP POLICY IF EXISTS ecommerce_order_items_auth_all        ON public.ecommerce_order_items;
DROP POLICY IF EXISTS ecommerce_orders_auth_all             ON public.ecommerce_orders;
DROP POLICY IF EXISTS ecommerce_sync_queue_auth_all         ON public.ecommerce_sync_queue;
DROP POLICY IF EXISTS job_invoice_lines_auth_all            ON public.job_invoice_lines;
DROP POLICY IF EXISTS stock_value_log_auth_all              ON public.stock_value_log;
DROP POLICY IF EXISTS xero_mappings_auth_all                ON public.xero_mappings;
DROP POLICY IF EXISTS shift_templates_authenticated_full_access ON public.shift_templates;

-- TO public, auth.role() = 'authenticated' (these ALSO let clients in):
DROP POLICY IF EXISTS auth_all_components ON public.job_components;
DROP POLICY IF EXISTS auth_all_dg_prep   ON public.job_drygoods_prep;
DROP POLICY IF EXISTS auth_all_dg_items  ON public.job_drygoods_prep_items;
DROP POLICY IF EXISTS auth_all_quality   ON public.job_quality_checks;
DROP POLICY IF EXISTS auth_all_wm        ON public.job_weights_measures;
DROP POLICY IF EXISTS leave_all          ON public.leave_requests;
DROP POLICY IF EXISTS roster_all         ON public.roster_shifts;
DROP POLICY IF EXISTS geofence_all       ON public.geofence_settings;
DROP POLICY IF EXISTS geofence_read      ON public.geofence_settings;
-- suppliers had generically-named open policies:
DROP POLICY IF EXISTS "read"   ON public.suppliers;
DROP POLICY IF EXISTS "insert" ON public.suppliers;
DROP POLICY IF EXISTS "update" ON public.suppliers;

-- Note: leave_requests keeps its employee own-row policies
-- (user_id = auth.uid()) and admin policies; staff_all (is_staff())
-- preserves manager visibility. geofence_settings keeps geofence_update
-- (director-scoped). staff keeps admin_manage_staff / staff_see_all_staff.
-- tasks keeps its staff_* / admin_delete_tasks policies. All redundant
-- with staff_all but harmless.
