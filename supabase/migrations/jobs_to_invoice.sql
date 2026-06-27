-- ============================================================
-- Jobs to Invoice — DB migration
-- Safe to re-run: idempotent ALTERs, CREATE OR REPLACE, IF NOT EXISTS,
-- ON CONFLICT DO NOTHING, DROP POLICY IF EXISTS.
-- ============================================================

-- ── 1. xero_mappings.default_unit_price ──────────────────────────────────────
-- Global default unit price per mapping row. Used as the fallback when a
-- client has no per-client override in client_invoice_rates.
ALTER TABLE xero_mappings
  ADD COLUMN IF NOT EXISTS default_unit_price numeric(10,2);

-- ── 2. Seed the one missing revenue mapping for this flow ────────────────────
-- bottling_sales, pallet_supply, colouring_charges, freight_courier already
-- exist from phase 1. dilution_charges is new.
INSERT INTO xero_mappings (mapping_type, mapping_key, description) VALUES
  ('revenue', 'dilution_charges', 'Dilution Charges')
ON CONFLICT (mapping_type, mapping_key) DO NOTHING;

-- ── 3. client_invoice_rates ──────────────────────────────────────────────────
-- Per-client override of unit_price keyed on (client_id, line_type).
-- A NULL or missing row means "use xero_mappings.default_unit_price".
--
-- updated_by intentionally has NO foreign key to app_users: the column type
-- there is not verified in the repo and we want this migration to apply on
-- any environment without a type-mismatch failure. The uuid is still a useful
-- audit trail when present.
CREATE TABLE IF NOT EXISTS client_invoice_rates (
  client_id   text          NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  line_type   text          NOT NULL,
  unit_price  numeric(10,2) NOT NULL,
  updated_at  timestamptz   DEFAULT now(),
  updated_by  uuid,
  PRIMARY KEY (client_id, line_type)
);
ALTER TABLE client_invoice_rates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "client_invoice_rates_auth_all" ON client_invoice_rates;
CREATE POLICY "client_invoice_rates_auth_all" ON client_invoice_rates
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON client_invoice_rates TO authenticated;

-- ── 4. job_invoice_lines (as-billed snapshot) ────────────────────────────────
-- Belt-and-braces: CREATE first so this script works whether phase 1 created
-- the table or not, then ALTER ADD COLUMN IF NOT EXISTS for the full set.
CREATE TABLE IF NOT EXISTS job_invoice_lines (
  id         bigserial PRIMARY KEY,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE job_invoice_lines
  ADD COLUMN IF NOT EXISTS job_id            text,
  ADD COLUMN IF NOT EXISTS line_type         text,
  ADD COLUMN IF NOT EXISTS description       text,
  ADD COLUMN IF NOT EXISTS quantity          numeric,
  ADD COLUMN IF NOT EXISTS unit_price        numeric(10,2),
  ADD COLUMN IF NOT EXISTS xero_account_key  text,
  ADD COLUMN IF NOT EXISTS xero_account_code text,
  ADD COLUMN IF NOT EXISTS xero_tax_type     text,
  ADD COLUMN IF NOT EXISTS position          int,
  ADD COLUMN IF NOT EXISTS created_at        timestamptz DEFAULT now();
ALTER TABLE job_invoice_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "job_invoice_lines_auth_all" ON job_invoice_lines;
CREATE POLICY "job_invoice_lines_auth_all" ON job_invoice_lines
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON job_invoice_lines TO authenticated;

-- ── 5. jobs.xero_invoice_number (small helper column) ────────────────────────
-- Keeps the toast/deep-link readable without an extra Xero round-trip.
ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS xero_invoice_number text;

-- ── 6. job_invoice_record_push RPC ───────────────────────────────────────────
-- Called once from xero-oauth EF after a successful Xero invoice POST.
-- Atomically writes the line snapshot AND updates the parent job. Without this
-- RPC, a snapshot insert failure after Xero accepted the invoice could leave
-- the job listed as not-yet-invoiced even though the draft exists in Xero.
CREATE OR REPLACE FUNCTION public.job_invoice_record_push(
  p_job_id          text,
  p_invoice_id      text,
  p_invoice_number  text,
  p_lines           jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO job_invoice_lines
    (job_id, line_type, description, quantity, unit_price,
     xero_account_key, xero_account_code, xero_tax_type, position)
  SELECT p_job_id,
         (l->>'line_type'),
         (l->>'description'),
         NULLIF(l->>'quantity', '')::numeric,
         NULLIF(l->>'unit_price', '')::numeric,
         (l->>'xero_account_key'),
         (l->>'xero_account_code'),
         (l->>'xero_tax_type'),
         NULLIF(l->>'position', '')::int
    FROM jsonb_array_elements(p_lines) l;

  UPDATE jobs
     SET xero_invoice_id     = p_invoice_id,
         xero_invoice_number = p_invoice_number
   WHERE id = p_job_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.job_invoice_record_push(text, text, text, jsonb)
  TO authenticated, service_role;
