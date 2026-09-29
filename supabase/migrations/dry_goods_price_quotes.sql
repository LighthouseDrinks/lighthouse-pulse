-- Dry goods pricing quotes. One saved component price for one client.
-- Staff only: rows hold supplier cost and margin, which stay off the client portal.

CREATE TABLE IF NOT EXISTS public.dry_goods_price_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES public.clients(id),
  component_key text NOT NULL,
  component_label text NOT NULL,
  description text NOT NULL,
  supplier_unit_price numeric(12,4) NOT NULL,
  price_unit text NOT NULL,
  bottles_per_case integer,
  quantity numeric(12,3) NOT NULL,
  transport_amount numeric(12,2) NOT NULL DEFAULT 0,
  transport_mode text NOT NULL DEFAULT 'order',
  tooling_cost numeric(12,2) NOT NULL DEFAULT 0,
  tooling_mode text NOT NULL DEFAULT 'included',
  margin_pct numeric(5,2) NOT NULL DEFAULT 30,
  moq numeric(12,3),
  overage_pct numeric(6,2) NOT NULL DEFAULT 0,
  lead_time text,
  valid_until date,
  note text,
  sell_unit_price numeric(14,6) NOT NULL,
  sell_component_total numeric(14,2) NOT NULL,
  customer_total numeric(14,2) NOT NULL,
  emailed_to text,
  emailed_at timestamptz,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dry_goods_price_quotes_price_unit CHECK (price_unit IN ('each', 'per_1000', 'per_case')),
  CONSTRAINT dry_goods_price_quotes_transport_mode CHECK (transport_mode IN ('order', 'per_unit')),
  CONSTRAINT dry_goods_price_quotes_tooling_mode CHECK (tooling_mode IN ('included', 'separate')),
  CONSTRAINT dry_goods_price_quotes_qty CHECK (quantity > 0),
  CONSTRAINT dry_goods_price_quotes_supplier CHECK (supplier_unit_price >= 0 AND supplier_unit_price < 1000000),
  CONSTRAINT dry_goods_price_quotes_transport CHECK (transport_amount >= 0),
  CONSTRAINT dry_goods_price_quotes_tooling CHECK (tooling_cost >= 0),
  CONSTRAINT dry_goods_price_quotes_margin CHECK (margin_pct >= 0 AND margin_pct <= 80),
  CONSTRAINT dry_goods_price_quotes_overage CHECK (overage_pct >= 0 AND overage_pct <= 100),
  CONSTRAINT dry_goods_price_quotes_desc CHECK (char_length(btrim(description)) BETWEEN 1 AND 200),
  CONSTRAINT dry_goods_price_quotes_label CHECK (char_length(btrim(component_label)) BETWEEN 1 AND 80),
  CONSTRAINT dry_goods_price_quotes_key CHECK (char_length(btrim(component_key)) BETWEEN 1 AND 40),
  CONSTRAINT dry_goods_price_quotes_case CHECK (
    price_unit <> 'per_case' OR (bottles_per_case IS NOT NULL AND bottles_per_case > 0)
  ),
  CONSTRAINT dry_goods_price_quotes_note CHECK (note IS NULL OR char_length(note) <= 2000),
  CONSTRAINT dry_goods_price_quotes_lead CHECK (lead_time IS NULL OR char_length(lead_time) <= 80)
);

CREATE INDEX IF NOT EXISTS dry_goods_price_quotes_client_idx
  ON public.dry_goods_price_quotes (client_id, created_at DESC);

ALTER TABLE public.dry_goods_price_quotes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_all ON public.dry_goods_price_quotes;
CREATE POLICY staff_all ON public.dry_goods_price_quotes
  FOR ALL TO authenticated
  USING (public.is_staff())
  WITH CHECK (public.is_staff());

REVOKE ALL ON public.dry_goods_price_quotes FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.dry_goods_price_quotes TO authenticated;
GRANT ALL ON public.dry_goods_price_quotes TO service_role;
