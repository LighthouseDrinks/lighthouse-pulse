-- ============================================================
-- Finance / Xero Phase 1 — DB migration
-- Safe to re-run: all statements use IF NOT EXISTS / ON CONFLICT DO NOTHING
-- ============================================================

-- ── ALTER TABLE: clients ─────────────────────────────────────────────────────
ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS xero_contact_id         text,
  ADD COLUMN IF NOT EXISTS xero_contact_mapped_at  timestamptz,
  ADD COLUMN IF NOT EXISTS xero_contact_mapped_by  uuid REFERENCES app_users(id) ON DELETE SET NULL;

-- ── ALTER TABLE: jobs ────────────────────────────────────────────────────────
ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS xero_invoice_id       text,
  ADD COLUMN IF NOT EXISTS xero_pushed_at        timestamptz,
  ADD COLUMN IF NOT EXISTS xero_push_status      text,
  ADD COLUMN IF NOT EXISTS invoice_line_items     jsonb,
  ADD COLUMN IF NOT EXISTS invoice_payment_terms  text DEFAULT '30_days';

-- ── TABLE: xero_connection ───────────────────────────────────────────────────
-- Stores the live OAuth tokens. Authenticated users cannot access this table
-- directly — they read through xero_connection_public (view below).
CREATE TABLE IF NOT EXISTS xero_connection (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        text        NOT NULL,
  tenant_name      text        NOT NULL,
  access_token     text        NOT NULL,
  refresh_token    text        NOT NULL,
  token_expiry     timestamptz NOT NULL,
  connected_by     uuid        REFERENCES app_users(id) ON DELETE SET NULL,
  connected_at     timestamptz NOT NULL DEFAULT now(),
  disconnected_at  timestamptz,
  is_active        boolean     NOT NULL DEFAULT true,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE xero_connection ENABLE ROW LEVEL SECURITY;

-- Deny all access to authenticated and anon roles (service_role bypasses RLS)
REVOKE ALL ON xero_connection FROM authenticated, anon;

-- Partial unique index: only one active connection at a time
CREATE UNIQUE INDEX IF NOT EXISTS xero_connection_one_active
  ON xero_connection (is_active)
  WHERE is_active = true;

-- ── VIEW: xero_connection_public ─────────────────────────────────────────────
-- Exposes only non-secret columns. Runs with creator (postgres) privileges,
-- intentionally bypassing the base-table RLS so the SPA can read connection
-- state without seeing access_token or refresh_token.
CREATE OR REPLACE VIEW xero_connection_public AS
  SELECT
    id,
    tenant_id,
    tenant_name,
    connected_by,
    connected_at,
    disconnected_at,
    is_active,
    token_expiry,
    updated_at
  FROM xero_connection;

GRANT SELECT ON xero_connection_public TO authenticated;

COMMENT ON VIEW xero_connection_public IS
  'Intentionally bypasses base-table RLS to expose non-secret columns. '
  'Tokens (access_token, refresh_token) are never selected. '
  'Supabase linter will flag this as a Security Definer View — this is intentional.';

-- ── TABLE: xero_mappings ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS xero_mappings (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  mapping_type        text        NOT NULL,   -- 'revenue' | 'asset'
  mapping_key         text        NOT NULL,   -- slug e.g. 'bottling_sales'
  description         text,
  xero_account_code   text,
  xero_account_name   text,
  xero_tax_type       text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid        REFERENCES app_users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mapping_type, mapping_key)
);

ALTER TABLE xero_mappings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "xero_mappings_auth_all" ON xero_mappings;
CREATE POLICY "xero_mappings_auth_all"
  ON xero_mappings FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: ecommerce_stores ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce_stores (
  id              uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text    NOT NULL,
  platform        text    NOT NULL,   -- 'shopify' | 'woocommerce' | 'other'
  store_url       text,
  api_key         text,               -- encrypted at rest via service role
  api_secret      text,               -- encrypted at rest via service role
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid    REFERENCES app_users(id) ON DELETE SET NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE ecommerce_stores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ecommerce_stores_auth_all" ON ecommerce_stores;
CREATE POLICY "ecommerce_stores_auth_all"
  ON ecommerce_stores FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: ecommerce_orders ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce_orders (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        uuid        NOT NULL REFERENCES ecommerce_stores(id) ON DELETE CASCADE,
  external_id     text        NOT NULL,
  order_number    text,
  customer_name   text,
  customer_email  text,
  total_amount    numeric(12,2),
  currency        text        DEFAULT 'EUR',
  status          text        NOT NULL DEFAULT 'pending',
  ordered_at      timestamptz,
  synced_at       timestamptz NOT NULL DEFAULT now(),
  raw_data        jsonb,
  UNIQUE (store_id, external_id)
);

ALTER TABLE ecommerce_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ecommerce_orders_auth_all" ON ecommerce_orders;
CREATE POLICY "ecommerce_orders_auth_all"
  ON ecommerce_orders FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: ecommerce_order_items ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce_order_items (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid        NOT NULL REFERENCES ecommerce_orders(id) ON DELETE CASCADE,
  sku             text,
  product_name    text        NOT NULL,
  quantity        integer     NOT NULL DEFAULT 1,
  unit_price      numeric(12,2),
  line_total      numeric(12,2)
);

ALTER TABLE ecommerce_order_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ecommerce_order_items_auth_all" ON ecommerce_order_items;
CREATE POLICY "ecommerce_order_items_auth_all"
  ON ecommerce_order_items FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: ecommerce_sync_queue ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce_sync_queue (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        uuid        NOT NULL REFERENCES ecommerce_stores(id) ON DELETE CASCADE,
  action          text        NOT NULL,   -- 'sync_orders' | 'sync_products'
  status          text        NOT NULL DEFAULT 'pending',
  scheduled_at    timestamptz NOT NULL DEFAULT now(),
  started_at      timestamptz,
  completed_at    timestamptz,
  error_message   text,
  created_by      uuid        REFERENCES app_users(id) ON DELETE SET NULL
);

ALTER TABLE ecommerce_sync_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ecommerce_sync_queue_auth_all" ON ecommerce_sync_queue;
CREATE POLICY "ecommerce_sync_queue_auth_all"
  ON ecommerce_sync_queue FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: job_invoice_lines ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS job_invoice_lines (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id            text        NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  mapping_key       text        NOT NULL,
  description       text,
  quantity          numeric(12,4) NOT NULL DEFAULT 1,
  unit_price        numeric(12,4) NOT NULL DEFAULT 0,
  line_total        numeric(12,4) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  xero_line_item_id text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE job_invoice_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "job_invoice_lines_auth_all" ON job_invoice_lines;
CREATE POLICY "job_invoice_lines_auth_all"
  ON job_invoice_lines FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: credit_control_templates ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS credit_control_templates (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text        NOT NULL,
  subject         text        NOT NULL,
  body_html       text        NOT NULL,
  trigger_days    integer     NOT NULL,  -- days overdue
  is_active       boolean     NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid        REFERENCES app_users(id) ON DELETE SET NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE credit_control_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "credit_control_templates_auth_all" ON credit_control_templates;
CREATE POLICY "credit_control_templates_auth_all"
  ON credit_control_templates FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: credit_control_log ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS credit_control_log (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id       text        REFERENCES clients(id) ON DELETE SET NULL,
  invoice_id      text,
  template_id     uuid        REFERENCES credit_control_templates(id) ON DELETE SET NULL,
  sent_at         timestamptz NOT NULL DEFAULT now(),
  sent_by         uuid        REFERENCES app_users(id) ON DELETE SET NULL,
  recipient_email text,
  days_overdue    integer
);

ALTER TABLE credit_control_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "credit_control_log_auth_all" ON credit_control_log;
CREATE POLICY "credit_control_log_auth_all"
  ON credit_control_log FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── TABLE: stock_value_log ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_value_log (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_date   date        NOT NULL,
  total_value     numeric(14,2) NOT NULL,
  breakdown       jsonb,
  xero_journal_id text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid        REFERENCES app_users(id) ON DELETE SET NULL,
  UNIQUE (snapshot_date)
);

ALTER TABLE stock_value_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "stock_value_log_auth_all" ON stock_value_log;
CREATE POLICY "stock_value_log_auth_all"
  ON stock_value_log FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ── RPC FUNCTIONS (atomic Xero operations) ───────────────────────────────────
-- These are called by the xero-oauth edge function (service role) to perform
-- Xero connect/refresh inside a single Postgres transaction, avoiding races.

-- xero_do_connect: atomically deactivates all previous connections, inserts a
-- new active one, and (if the tenant changed) clears stale client mappings.
-- SECURITY DEFINER runs as the owner (postgres) so it bypasses RLS on
-- xero_connection, which is otherwise locked down to service_role only.
CREATE OR REPLACE FUNCTION xero_do_connect(
  p_tenant_id     text,
  p_tenant_name   text,
  p_access_token  text,
  p_refresh_token text,
  p_token_expiry  timestamptz,
  p_connected_by  uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_prev_tenant_id text;
  v_tenant_changed boolean := false;
BEGIN
  SELECT tenant_id INTO v_prev_tenant_id
    FROM xero_connection WHERE is_active = true LIMIT 1;

  v_tenant_changed := (v_prev_tenant_id IS NOT NULL AND v_prev_tenant_id <> p_tenant_id);

  UPDATE xero_connection
    SET is_active = false, disconnected_at = now()
    WHERE is_active = true;

  INSERT INTO xero_connection
    (tenant_id, tenant_name, access_token, refresh_token,
     token_expiry, connected_by, is_active, connected_at, updated_at)
  VALUES
    (p_tenant_id, p_tenant_name, p_access_token, p_refresh_token,
     p_token_expiry, p_connected_by, true, now(), now());

  IF v_tenant_changed THEN
    UPDATE clients
      SET xero_contact_id        = null,
          xero_contact_mapped_at  = null,
          xero_contact_mapped_by  = null
      WHERE xero_contact_id IS NOT NULL;
  END IF;

  RETURN jsonb_build_object(
    'tenant_changed',   v_tenant_changed,
    'previous_tenant',  v_prev_tenant_id
  );
END;
$$;

COMMENT ON FUNCTION xero_do_connect IS
  'Atomic Xero OAuth callback: deactivates old connections, inserts new active '
  'row, clears client mappings when tenant changes. Called by xero-oauth edge '
  'function with service role.';

-- xero_do_refresh: writes new tokens only when the active connection still has
-- an expired (or about-to-expire) token, preventing a double-refresh race.
-- Returns TRUE if the update happened, FALSE if another caller already refreshed.
CREATE OR REPLACE FUNCTION xero_do_refresh(
  p_access_token  text,
  p_refresh_token text,
  p_token_expiry  timestamptz
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_rows int;
BEGIN
  UPDATE xero_connection
    SET access_token  = p_access_token,
        refresh_token = p_refresh_token,
        token_expiry  = p_token_expiry,
        updated_at    = now()
    WHERE is_active = true
      AND token_expiry <= now() + interval '5 minutes';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

COMMENT ON FUNCTION xero_do_refresh IS
  'Conditional token refresh: only writes when the active token is still within '
  '5 minutes of expiry, eliminating the parallel-refresh double-use race.';

-- Grant execute to service_role (edge function) only
GRANT EXECUTE ON FUNCTION xero_do_connect TO service_role;
GRANT EXECUTE ON FUNCTION xero_do_refresh TO service_role;
REVOKE EXECUTE ON FUNCTION xero_do_connect FROM PUBLIC, authenticated, anon;
REVOKE EXECUTE ON FUNCTION xero_do_refresh FROM PUBLIC, authenticated, anon;

-- ── SEED: xero_mappings ──────────────────────────────────────────────────────
INSERT INTO xero_mappings (mapping_type, mapping_key, description) VALUES
  ('revenue', 'bottling_sales',    'Bottling Sales'),
  ('revenue', 'ecommerce_sales',   'Ecommerce Sales'),
  ('revenue', 'freight_courier',   'Freight & Courier'),
  ('revenue', 'gift_cards',        'Gift Cards'),
  ('revenue', 'colouring_charges', 'Colouring Charges'),
  ('revenue', 'chill_filtration',  'Chill Filtration'),
  ('revenue', 'pallet_supply',     'Pallet Supply'),
  ('revenue', 'outbound_revenue',  'Outbound Revenue'),
  ('revenue', 'label_application', 'Label Application'),
  ('asset',   'stock_on_hand',     'Stock on Hand (Asset)')
ON CONFLICT (mapping_type, mapping_key) DO NOTHING;
