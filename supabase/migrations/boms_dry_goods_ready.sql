-- Staff attestation that liquid + dry-goods SKUs are on a draft/pending BOM,
-- so it can be used to create a Pulse job before barcodes / pallet / QC lock.
ALTER TABLE public.boms
  ADD COLUMN IF NOT EXISTS dry_goods_ready boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.boms.dry_goods_ready IS
  'True when staff have marked liquid and dry-goods SKUs complete. Draft/pending BOMs cannot create a job until this is set. Approved BOMs ignore it.';

-- Existing jobs already started from a draft — do not block further edits overnight.
UPDATE public.boms
SET dry_goods_ready = true
WHERE id IN (SELECT DISTINCT bom_id FROM public.jobs WHERE bom_id IS NOT NULL);
