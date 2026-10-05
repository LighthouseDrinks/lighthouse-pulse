-- Sales forecast. One row is one expected order for a customer in a year,
-- optionally placed in a month. Staff only — client portal accounts cannot
-- read or write it.

CREATE TABLE IF NOT EXISTS public.sales_forecast_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES public.clients(id),
  year integer NOT NULL,
  month integer,
  bottles numeric(14,2),
  value_eur numeric(14,2),
  notes text,
  created_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sales_forecast_lines_year CHECK (year BETWEEN 2000 AND 2100),
  CONSTRAINT sales_forecast_lines_month CHECK (month IS NULL OR month BETWEEN 1 AND 12),
  CONSTRAINT sales_forecast_lines_bottles CHECK (bottles IS NULL OR (bottles >= 0 AND bottles < 100000000)),
  CONSTRAINT sales_forecast_lines_value CHECK (value_eur IS NULL OR (value_eur >= 0 AND value_eur < 100000000)),
  CONSTRAINT sales_forecast_lines_amount CHECK (coalesce(bottles, 0) > 0 OR coalesce(value_eur, 0) > 0),
  CONSTRAINT sales_forecast_lines_notes CHECK (notes IS NULL OR char_length(notes) <= 2000)
);

CREATE INDEX IF NOT EXISTS sales_forecast_lines_year_idx
  ON public.sales_forecast_lines (year, month, created_at);

CREATE OR REPLACE FUNCTION public.sales_forecast_lines_touch()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at := now();
  IF NEW.notes IS NOT NULL THEN
    NEW.notes := nullif(btrim(NEW.notes), '');
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.sales_forecast_lines_touch() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS sales_forecast_lines_touch ON public.sales_forecast_lines;
CREATE TRIGGER sales_forecast_lines_touch
  BEFORE INSERT OR UPDATE ON public.sales_forecast_lines
  FOR EACH ROW
  EXECUTE FUNCTION public.sales_forecast_lines_touch();

ALTER TABLE public.sales_forecast_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sales_forecast_lines_staff ON public.sales_forecast_lines;
CREATE POLICY sales_forecast_lines_staff ON public.sales_forecast_lines
  FOR ALL TO authenticated
  USING (public.is_staff())
  WITH CHECK (public.is_staff());

REVOKE ALL ON public.sales_forecast_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sales_forecast_lines TO authenticated;
GRANT ALL ON public.sales_forecast_lines TO service_role;
