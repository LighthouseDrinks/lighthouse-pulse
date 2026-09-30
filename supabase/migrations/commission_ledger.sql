-- Commission ledger. FYI commission for sales logged by month.
-- Visible and editable only by managing director, operations director,
-- commercial manager, financial controller, and business analyst.
-- A new row is always stamped with the current Europe/Dublin month.
-- Unpaid rows are shown again on later months by the app; the stored
-- month does not move.

CREATE TABLE IF NOT EXISTS public.commission_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES public.clients(id),
  product_name text NOT NULL,
  invoice_value numeric(14,2) NOT NULL,
  paid boolean NOT NULL DEFAULT false,
  management_approved boolean NOT NULL DEFAULT false,
  company text NOT NULL,
  period_month date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commission_ledger_company CHECK (company IN ('hibernia', 'lighthouse')),
  CONSTRAINT commission_ledger_invoice CHECK (invoice_value >= 0 AND invoice_value < 100000000),
  CONSTRAINT commission_ledger_product CHECK (char_length(btrim(product_name)) BETWEEN 1 AND 200),
  CONSTRAINT commission_ledger_period_day CHECK (extract(day FROM period_month) = 1)
);

CREATE INDEX IF NOT EXISTS commission_ledger_period_idx
  ON public.commission_ledger (period_month, created_at);

CREATE OR REPLACE FUNCTION public.can_use_commission_ledger()
  RETURNS boolean
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
  SELECT public.current_app_user_role() IN (
    'managing_director',
    'operations_director',
    'commercial_manager',
    'financial_controller',
    'business_analyst'
  );
$function$;

REVOKE ALL ON FUNCTION public.can_use_commission_ledger() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_use_commission_ledger() TO authenticated;

CREATE OR REPLACE FUNCTION public.commission_ledger_guard()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path TO 'public'
AS $function$
DECLARE
  dublin_month date;
BEGIN
  dublin_month := (date_trunc('month', timezone('Europe/Dublin', now())))::date;
  NEW.product_name := btrim(NEW.product_name);
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' THEN
    NEW.period_month := dublin_month;
  ELSIF NEW.period_month IS DISTINCT FROM OLD.period_month THEN
    RAISE EXCEPTION 'A commission row stays in the month it was logged';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.commission_ledger_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS commission_ledger_guard ON public.commission_ledger;
CREATE TRIGGER commission_ledger_guard
  BEFORE INSERT OR UPDATE ON public.commission_ledger
  FOR EACH ROW
  EXECUTE FUNCTION public.commission_ledger_guard();

ALTER TABLE public.commission_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS commission_ledger_staff ON public.commission_ledger;
CREATE POLICY commission_ledger_staff ON public.commission_ledger
  FOR ALL TO authenticated
  USING (public.can_use_commission_ledger())
  WITH CHECK (public.can_use_commission_ledger());

REVOKE ALL ON public.commission_ledger FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.commission_ledger TO authenticated;
GRANT ALL ON public.commission_ledger TO service_role;
