-- ============================================================
-- Finance / Xero Phase 2 — DB migration
-- Safe to re-run: all statements use IF NOT EXISTS / ON CONFLICT DO NOTHING /
-- CREATE OR REPLACE / DROP POLICY IF EXISTS.
-- Depends on finance_xero_phase1.sql being applied first.
-- ============================================================

-- ── ALTER TABLE: ecommerce_orders ────────────────────────────────────────────
-- Adds Xero push tracking + payment metadata so paid ecommerce orders can be
-- pushed to Xero as invoices AND paid against a clearing account in one go.
ALTER TABLE ecommerce_orders
  ADD COLUMN IF NOT EXISTS xero_contact_id   text,
  ADD COLUMN IF NOT EXISTS xero_invoice_id   text,
  ADD COLUMN IF NOT EXISTS xero_payment_id   text,
  ADD COLUMN IF NOT EXISTS xero_push_status  text,
  ADD COLUMN IF NOT EXISTS xero_pushed_at    timestamptz,
  ADD COLUMN IF NOT EXISTS xero_error        text,
  ADD COLUMN IF NOT EXISTS payment_gateway   text,
  ADD COLUMN IF NOT EXISTS payment_status    text;

-- ── ALTER TABLE: ecommerce_order_items ───────────────────────────────────────
-- item_type lets us distinguish product / shipping / discount / gift_card_issued
-- xero_account_key maps the line back to a xero_mappings row (mapping_key)
ALTER TABLE ecommerce_order_items
  ADD COLUMN IF NOT EXISTS item_type        text,
  ADD COLUMN IF NOT EXISTS xero_account_key text;

-- ── ALTER TABLE: ecommerce_stores ────────────────────────────────────────────
-- Note: is_active already exists from phase 1 — do NOT add it here.
ALTER TABLE ecommerce_stores
  ADD COLUMN IF NOT EXISTS connection_status     text DEFAULT 'disconnected',
  ADD COLUMN IF NOT EXISTS last_synced_at        timestamptz,
  ADD COLUMN IF NOT EXISTS orders_synced_count   int DEFAULT 0,
  ADD COLUMN IF NOT EXISTS revenue_synced        numeric(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS error_message         text,
  ADD COLUMN IF NOT EXISTS sync_from_date        date,
  ADD COLUMN IF NOT EXISTS xero_sales_account    text,
  ADD COLUMN IF NOT EXISTS xero_shipping_account text;

-- ── ALTER TABLE: credit_control_log ──────────────────────────────────────────
-- recipient_email already exists from phase 1; we add provider tracking only.
ALTER TABLE credit_control_log
  ADD COLUMN IF NOT EXISTS provider_message_id text,
  ADD COLUMN IF NOT EXISTS send_status         text;

-- ── SECURITY: lock down ecommerce_stores credentials ─────────────────────────
-- After this revoke, the SPA can no longer read or write the table directly.
-- All reads go via ecommerce_stores_public (view, credentials excluded).
-- All writes go via the ecommerce-sync edge function (service role).
REVOKE ALL ON ecommerce_stores FROM authenticated, anon;

DROP POLICY IF EXISTS "ecommerce_stores_auth_all" ON ecommerce_stores;

-- ── VIEW: ecommerce_stores_public ────────────────────────────────────────────
-- Exposes all non-credential columns. Filters out soft-deleted stores so the
-- UI never displays deactivated entries. Bypasses base-table RLS intentionally.
CREATE OR REPLACE VIEW ecommerce_stores_public AS
  SELECT
    id,
    name,
    platform,
    store_url,
    is_active,
    created_at,
    created_by,
    updated_at,
    connection_status,
    last_synced_at,
    orders_synced_count,
    revenue_synced,
    error_message,
    sync_from_date,
    xero_sales_account,
    xero_shipping_account
  FROM ecommerce_stores
  WHERE is_active = true;

GRANT SELECT ON ecommerce_stores_public TO authenticated;

COMMENT ON VIEW ecommerce_stores_public IS
  'Excludes api_key / api_secret. Credentials are accessed only via the '
  'ecommerce-sync edge function (service role). Filters out is_active=false rows.';

-- ── SEED: xero_mappings additions ────────────────────────────────────────────
-- ecommerce_payment_clearing is the asset/bank account that receives the
-- payment for each ecommerce invoice. Without it, paid Shopify orders would
-- sit in AR as if unpaid.
INSERT INTO xero_mappings (mapping_type, mapping_key, description) VALUES
  ('revenue', 'shipping_revenue',           'Shipping Revenue'),
  ('revenue', 'ecommerce_discounts',        'Ecommerce Discounts'),
  ('asset',   'ecommerce_payment_clearing', 'Ecommerce Payment Clearing')
ON CONFLICT (mapping_type, mapping_key) DO NOTHING;

-- ── SEED: credit_control_templates ───────────────────────────────────────────
-- Three default tones. Body is plain <p> markup only — no logos, no branding —
-- so the email reads like it came from a person, not a system. Placeholders
-- {{contact_name}}, {{invoice_number}}, {{amount_due}}, {{due_date}},
-- {{days_overdue}}, {{invoice_url}} are replaced by the credit-control edge fn.
INSERT INTO credit_control_templates (name, subject, body_html, trigger_days, is_active) VALUES
  (
    'soft',
    'Quick reminder — invoice {{invoice_number}}',
    '<p>Hi {{contact_name}},</p>'
    || '<p>Just a quick note that invoice {{invoice_number}} for {{amount_due}} '
    || 'fell due on {{due_date}}.</p>'
    || '<p>If it''s already on the way, please ignore this — otherwise a quick '
    || 'transfer when you get a moment would be great.</p>'
    || '<p>You can view the invoice here: {{invoice_url}}</p>'
    || '<p>Thanks,<br>Lighthouse Drinks</p>',
    1,
    true
  ),
  (
    'medium',
    'Following up — invoice {{invoice_number}} now {{days_overdue}} days overdue',
    '<p>Hi {{contact_name}},</p>'
    || '<p>Following up on invoice {{invoice_number}} for {{amount_due}}, which '
    || 'was due on {{due_date}} and is now {{days_overdue}} days overdue.</p>'
    || '<p>Could you let me know when we can expect payment? Happy to discuss '
    || 'if there''s anything I should know about.</p>'
    || '<p>Invoice link: {{invoice_url}}</p>'
    || '<p>Thanks,<br>Lighthouse Drinks</p>',
    14,
    true
  ),
  (
    'heavy',
    'Urgent — invoice {{invoice_number}} now {{days_overdue}} days overdue',
    '<p>Hi {{contact_name}},</p>'
    || '<p>Despite previous reminders, invoice {{invoice_number}} for {{amount_due}} '
    || '(due {{due_date}}) remains unpaid and is now {{days_overdue}} days overdue.</p>'
    || '<p>Please could you arrange payment this week, or contact me directly to '
    || 'agree a payment plan. We''ll need to put further orders on hold until '
    || 'this is resolved.</p>'
    || '<p>Invoice link: {{invoice_url}}</p>'
    || '<p>Thanks,<br>Lighthouse Drinks</p>',
    30,
    true
  )
ON CONFLICT DO NOTHING;

-- ── SEED: app_settings sender identity (empty by design) ─────────────────────
-- Must be filled in via Finance > Settings before any chase email can send.
-- The credit-control edge function refuses to send if either is empty.
-- app_settings.value is a JSON column, so an empty string is the JSON literal '""'.
INSERT INTO app_settings (key, value) VALUES
  ('credit_from_name',  '""'),
  ('credit_from_email', '""')
ON CONFLICT (key) DO NOTHING;
