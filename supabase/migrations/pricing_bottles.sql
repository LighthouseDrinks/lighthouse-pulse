-- Custom bottles for the pricing-tool dropdown (section 3).
-- Built-in bottles stay in the page. Rows added here are appended
-- under them and shared by every staff user.
-- Idempotent / safe to re-run.

CREATE TABLE IF NOT EXISTS public.pricing_bottles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  colour text NOT NULL,
  volume text NOT NULL,
  price numeric(10,3) NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pricing_bottles_name_len CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  CONSTRAINT pricing_bottles_colour_len CHECK (char_length(btrim(colour)) BETWEEN 1 AND 40),
  CONSTRAINT pricing_bottles_volume_len CHECK (char_length(btrim(volume)) BETWEEN 1 AND 20),
  CONSTRAINT pricing_bottles_price_nonneg CHECK (price >= 0 AND price < 10000)
);

-- One live bottle per name + colour + volume. Removed rows (is_active = false)
-- do not block adding the same bottle again.
CREATE UNIQUE INDEX IF NOT EXISTS pricing_bottles_identity_idx
  ON public.pricing_bottles (lower(btrim(name)), lower(btrim(colour)), lower(btrim(volume)))
  WHERE is_active;

ALTER TABLE public.pricing_bottles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_all ON public.pricing_bottles;
CREATE POLICY staff_all ON public.pricing_bottles
  FOR ALL TO authenticated
  USING (public.is_staff())
  WITH CHECK (public.is_staff());

REVOKE ALL ON public.pricing_bottles FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pricing_bottles TO authenticated;
GRANT ALL ON public.pricing_bottles TO service_role;
