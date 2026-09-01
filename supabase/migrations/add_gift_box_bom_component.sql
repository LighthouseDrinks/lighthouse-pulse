-- Split Gift Boxes off Monocarton: dedicated BOM component column.
-- Category "Gift Boxes" (id 9) already exists — do not INSERT a new row.
-- Quantity is per bottle (same as monocarton).
--
-- v_portal_boms is replaced (not dropped) so v_portal_bom_history stays intact.
-- The new column is appended at the end — Postgres CREATE OR REPLACE VIEW
-- only allows new columns at the end.

ALTER TABLE boms ADD COLUMN IF NOT EXISTS gift_box_sku_id text;
ALTER TABLE client_bom_submissions ADD COLUMN IF NOT EXISTS gift_box_sku_id text;

-- Hyde 25YO stored a Gift Boxes SKU (SKU-455 Piano wood, inactive) as monocarton.
UPDATE boms
SET gift_box_sku_id = monocarton_sku_id,
    monocarton_sku_id = NULL
WHERE id = 'BOM-007-MR4R8XCV'
  AND monocarton_sku_id IN (SELECT id FROM dry_goods_skus WHERE category_id = 9);

CREATE OR REPLACE FUNCTION public.lighthouse_bom_sku_ids(p_bom public.boms)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT ARRAY_REMOVE(ARRAY[
    p_bom.bottle_sku_id,
    p_bom.cork_sku_id,
    p_bom.ropp_sku_id,
    p_bom.foil_sku_id,
    p_bom.front_label_sku_id,
    p_bom.back_label_sku_id,
    p_bom.neck_label_sku_id,
    p_bom.outer_case_label_sku_id,
    p_bom.shipper_sku_id,
    p_bom.divider_sku_id,
    p_bom.string_twine_sku_id,
    p_bom.monocarton_sku_id,
    p_bom.gift_tube_sku_id,
    p_bom.tube_lid_sku_id,
    p_bom.tin_sku_id,
    p_bom.wire_sku_id,
    p_bom.medallion_sku_id,
    p_bom.coa_sku_id,
    p_bom.gift_box_label_sku_id,
    p_bom.gift_box_back_label_sku_id,
    p_bom.gift_box_sku_id
  ], NULL);
$function$;

REVOKE ALL ON FUNCTION public.lighthouse_bom_sku_ids(public.boms) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lighthouse_bom_sku_ids(public.boms) TO authenticated;

CREATE OR REPLACE VIEW public.v_portal_boms
  WITH (security_invoker = false)
AS
SELECT
  b.id,
  b.product_name,
  b.bom_status,
  b.revision_number,
  b.revised_at,
  b.revised_by,
  b.liquid_spec,
  b.volume_cl,
  b.abv,
  b.bottling_abv,
  b.chill_filtration,
  b.colouring,
  b.colour_spec,
  b.gi_verified,
  b.bottles_per_shipper,
  b.bottle_sku_id,
  b.cork_sku_id,
  b.ropp_sku_id,
  b.foil_sku_id,
  b.front_label_sku_id,
  b.back_label_sku_id,
  b.neck_label_sku_id,
  b.outer_case_label_sku_id,
  b.shipper_sku_id,
  b.divider_sku_id,
  b.string_twine_sku_id,
  b.monocarton_sku_id,
  b.gift_tube_sku_id,
  b.tube_lid_sku_id,
  b.tin_sku_id,
  b.wire_sku_id,
  b.medallion_sku_id,
  b.coa_sku_id,
  b.label_master_photos,
  b.locked_by,
  jsonb_strip_nulls(jsonb_build_object(
    'labelBarcode',   b.additional_info->'labelBarcode',
    'shipperBarcode', b.additional_info->'shipperBarcode',
    'intendedMarket', b.additional_info->'intendedMarket',
    'dutyStamp',      b.additional_info->'dutyStamp',
    'annex2',         b.additional_info->'annex2',
    'lotNumber',      b.additional_info->'lotNumber',
    'pallet',         b.additional_info->'pallet',
    'casesLayer',     b.additional_info->'casesLayer',
    'layersPallet',   b.additional_info->'layersPallet',
    'labelPosition',  b.additional_info->'labelPosition',
    'notes',          b.additional_info->'notes'
  )) AS additional_info,
  (b.client_id = 'CLI-000'
    AND b.client_id IS DISTINCT FROM public.current_app_user_client_id())
    AS is_lighthouse_produced,
  b.gift_box_label_sku_id,
  b.gift_box_back_label_sku_id,
  b.gift_box_sku_id
FROM public.boms b
WHERE public.is_client_user()
  AND b.bom_status = 'approved'
  AND (
    b.client_id = public.current_app_user_client_id()
    OR b.id IN (SELECT s.id FROM public.portal_shared_lighthouse_bom_ids() s)
  );

GRANT SELECT ON public.v_portal_boms TO authenticated;

NOTIFY pgrst, 'reload schema';
