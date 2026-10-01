-- An unpaid row stays on the month it was logged until Paid is ticked.
-- The screen hides it from that older month and shows it only on the
-- current month. Ticking Paid moves it onto the current Europe/Dublin
-- month so it stays there and joins that month's pot.

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
  ELSIF NEW.paid = true AND OLD.paid = false AND OLD.period_month < dublin_month THEN
    NEW.period_month := dublin_month;
  ELSIF NEW.period_month IS DISTINCT FROM OLD.period_month THEN
    RAISE EXCEPTION 'A commission row stays in the month it was logged';
  END IF;
  RETURN NEW;
END;
$function$;
