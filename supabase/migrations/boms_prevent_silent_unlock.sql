-- ============================================================
-- Block silent unlock of locked BOMs.
--
-- Save Draft / Submit used to PATCH bom_status='draft' on every
-- save, using a stale in-memory lock check. That could revert an
-- approved or pending BOM without writing bom_history.
--
-- Official Return to Draft always clears locked_by. This trigger
-- only allows approved/pending → draft when locked_by is cleared.
-- ============================================================

CREATE OR REPLACE FUNCTION public.boms_prevent_silent_unlock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.bom_status IN ('approved', 'pending')
     AND NEW.bom_status = 'draft'
     AND NEW.locked_by IS NOT NULL
     AND btrim(NEW.locked_by) <> '' THEN
    RAISE EXCEPTION 'Cannot revert a locked BOM to draft without clearing locked_by'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_boms_prevent_silent_unlock ON public.boms;
CREATE TRIGGER trg_boms_prevent_silent_unlock
  BEFORE UPDATE ON public.boms
  FOR EACH ROW
  EXECUTE FUNCTION public.boms_prevent_silent_unlock();
