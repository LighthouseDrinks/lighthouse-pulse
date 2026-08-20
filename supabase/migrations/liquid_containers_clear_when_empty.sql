-- When a vessel / tank / IBC is fully emptied, leftover product metadata
-- must not stay on the row. Empty stock that still shows a CBW rotation,
-- spirit type, ABV, LPA price, location, or liquid owner is how drained
-- vessels keep looking full in the inventory.
--
-- This trigger is the backstop for every write path (job close, transfer,
-- blend, dilute, disgorge, manual edit). Vessel identity is left alone:
-- reference, type, capacity, client_id (vessel owner), vessel_id,
-- fill_number / previous_contents (cask history), notes, archive flags.
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS trg_liquid_container_clear_when_empty ON public.liquid_containers;
--   DROP FUNCTION IF EXISTS public.liquid_container_clear_when_empty();
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.liquid_container_clear_when_empty()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.current_litres IS NULL OR NEW.current_litres <= 0 THEN
    NEW.current_litres := 0;
    NEW.current_lpa := 0;
    NEW.status := 'empty';
    NEW.spirit_type := NULL;
    NEW.cbw_rotation := NULL;
    NEW.abv := NULL;
    NEW.location := NULL;
    NEW.lpa_price := NULL;
    NEW.liquid_owner_client_id := NULL;
    NEW.fill_date := NULL;
    NEW.distillation_date := NULL;
    NEW.blend_id := NULL;
    NEW.ola := NULL;
    NEW.supplier_id := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_liquid_container_clear_when_empty ON public.liquid_containers;
CREATE TRIGGER trg_liquid_container_clear_when_empty
  BEFORE INSERT OR UPDATE ON public.liquid_containers
  FOR EACH ROW
  EXECUTE FUNCTION public.liquid_container_clear_when_empty();

-- One-time sweep of vessels that are already at 0 L but still carry product data.
UPDATE public.liquid_containers
   SET current_litres = 0
 WHERE COALESCE(current_litres, 0) <= 0;
