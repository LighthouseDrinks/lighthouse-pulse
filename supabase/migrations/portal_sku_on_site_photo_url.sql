-- Add photo_url to the portal SKU view so clients can open component photos
-- on shared Lighthouse BOMs and the Lighthouse Procured Components list.
-- Does not expose supplier, cost, or location.

CREATE OR REPLACE VIEW public.v_portal_sku_on_site
  WITH (security_invoker = false)
AS
SELECT
  sku.id AS sku_id,
  sku.description,
  sku.volume,
  sku.abv,
  sku.region,
  cat.name AS category_name,
  COALESCE((
    SELECT SUM(bt.quantity_remaining)
    FROM public.dry_goods_batches bt
    WHERE bt.sku_id = sku.id
  ), 0)::bigint AS qty_on_site,
  (sku.client_id = 'CLI-000'
    AND sku.client_id IS DISTINCT FROM public.current_app_user_client_id())
    AS is_lighthouse_sku,
  (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', sb.id,
      'product_name', sb.product_name
    ) ORDER BY sb.product_name), '[]'::jsonb)
    FROM public.boms sb
    WHERE sb.id IN (SELECT x.id FROM public.portal_shared_lighthouse_bom_ids() x)
      AND sku.id = ANY (public.lighthouse_bom_sku_ids(sb))
  ) AS used_on_boms,
  sku.photo_url
FROM public.dry_goods_skus sku
LEFT JOIN public.dry_goods_categories cat ON cat.id = sku.category_id
WHERE public.is_client_user()
  AND sku.is_active = true
  AND (
    sku.client_id = public.current_app_user_client_id()
    OR (
      sku.client_id = 'CLI-000'
      AND EXISTS (
        SELECT 1 FROM public.boms sb
        WHERE sb.id IN (SELECT x.id FROM public.portal_shared_lighthouse_bom_ids() x)
          AND sku.id = ANY (public.lighthouse_bom_sku_ids(sb))
      )
    )
  );

GRANT SELECT ON public.v_portal_sku_on_site TO authenticated;
NOTIFY pgrst, 'reload schema';
