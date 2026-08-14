-- ============================================================
-- Shared Lighthouse BOM visibility on the client portal
--
-- Clients must not SELECT jobs / boms / dry_goods_* / job_components
-- for CLI-000 rows (those tables carry finance, suppliers, unit_cost).
-- Portal reads column-safe SECURITY DEFINER views instead.
--
-- Visibility of an approved CLI-000 BOM (any of):
--   1. additional_info.includeClientId = current client
--   2. any dry-goods SKU on the BOM is owned by the current client
--   3. a bom_portal_shares row
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── Junction: explicit "show on portal for" ─────────────────
CREATE TABLE IF NOT EXISTS public.bom_portal_shares (
  bom_id    text NOT NULL REFERENCES public.boms(id) ON DELETE CASCADE,
  client_id text NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bom_id, client_id)
);

ALTER TABLE public.bom_portal_shares ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bom_portal_shares_staff_all ON public.bom_portal_shares;
CREATE POLICY bom_portal_shares_staff_all ON public.bom_portal_shares
  FOR ALL TO authenticated
  USING (public.is_staff())
  WITH CHECK (public.is_staff());

REVOKE ALL ON public.bom_portal_shares FROM PUBLIC, anon;
GRANT SELECT, INSERT, DELETE ON public.bom_portal_shares TO authenticated;

-- ── SKU ids on a BOM (dry goods only — not liquid) ──────────
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
    p_bom.coa_sku_id
  ], NULL);
$function$;

REVOKE ALL ON FUNCTION public.lighthouse_bom_sku_ids(public.boms) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lighthouse_bom_sku_ids(public.boms) TO authenticated;

-- ── Approved CLI-000 BOM ids visible to the calling client ──
CREATE OR REPLACE FUNCTION public.portal_shared_lighthouse_bom_ids()
RETURNS TABLE(id text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT b.id
  FROM public.boms b
  WHERE b.client_id = 'CLI-000'
    AND b.bom_status = 'approved'
    AND public.current_app_user_client_id() IS NOT NULL
    AND (
      NULLIF(btrim(b.additional_info->>'includeClientId'), '')
        = public.current_app_user_client_id()
      OR EXISTS (
        SELECT 1 FROM public.bom_portal_shares s
        WHERE s.bom_id = b.id
          AND s.client_id = public.current_app_user_client_id()
      )
      OR EXISTS (
        SELECT 1 FROM public.dry_goods_skus sku
        WHERE sku.client_id = public.current_app_user_client_id()
          AND sku.id = ANY (public.lighthouse_bom_sku_ids(b))
      )
    );
$function$;

REVOKE ALL ON FUNCTION public.portal_shared_lighthouse_bom_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_shared_lighthouse_bom_ids() TO authenticated;

CREATE OR REPLACE FUNCTION public.portal_client_can_use_bom(p_bom_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    p_bom_id IS NULL
    OR EXISTS (
      SELECT 1 FROM public.boms b
      WHERE b.id = p_bom_id
        AND b.bom_status = 'approved'
        AND b.client_id = public.current_app_user_client_id()
    )
    OR EXISTS (
      SELECT 1 FROM public.portal_shared_lighthouse_bom_ids() s
      WHERE s.id = p_bom_id
    );
$function$;

REVOKE ALL ON FUNCTION public.portal_client_can_use_bom(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_client_can_use_bom(text) TO authenticated;

-- ── Submission guard: cannot attach an invisible / draft BOM ─
DROP POLICY IF EXISTS cjs_client_insert ON public.client_job_submissions;
CREATE POLICY cjs_client_insert ON public.client_job_submissions
  FOR INSERT TO authenticated
  WITH CHECK (
    client_id = public.current_app_user_client_id()
    AND status = 'submitted'
    AND public.portal_client_can_use_bom(bom_id)
  );

-- ── Column-safe portal views (DEFINER: clients have no base SELECT)
DROP VIEW IF EXISTS public.v_portal_boms CASCADE;
CREATE VIEW public.v_portal_boms
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
    AS is_lighthouse_produced
FROM public.boms b
WHERE public.is_client_user()
  AND b.bom_status = 'approved'
  AND (
    b.client_id = public.current_app_user_client_id()
    OR b.id IN (SELECT s.id FROM public.portal_shared_lighthouse_bom_ids() s)
  );

DROP VIEW IF EXISTS public.v_portal_jobs CASCADE;
CREATE VIEW public.v_portal_jobs
  WITH (security_invoker = false)
AS
SELECT
  j.id,
  j.bom_id,
  j.product_name,
  j.stage,
  j.job_target_type,
  j.bottle_target,
  j.liquid_litres,
  j.scheduled_start,
  j.scheduled_date,
  j.job_ready_date,
  j.created_at,
  j.actual_bottles_produced,
  j.date_completed,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.notes
    ELSE NULL
  END AS notes,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.po_number
    WHEN EXISTS (
      SELECT 1 FROM public.client_job_submissions s
      WHERE s.approved_job_id = j.id
        AND s.client_id = public.current_app_user_client_id()
    ) THEN j.po_number
    ELSE NULL
  END AS po_number,
  CASE
    WHEN j.client_id = public.current_app_user_client_id() THEN j.po_attachments
    WHEN EXISTS (
      SELECT 1 FROM public.client_job_submissions s
      WHERE s.approved_job_id = j.id
        AND s.client_id = public.current_app_user_client_id()
    ) THEN j.po_attachments
    ELSE NULL
  END AS po_attachments,
  (j.client_id = 'CLI-000'
    AND j.client_id IS DISTINCT FROM public.current_app_user_client_id())
    AS is_lighthouse_produced
FROM public.jobs j
WHERE public.is_client_user()
  AND (
    j.client_id = public.current_app_user_client_id()
    OR (
      j.client_id = 'CLI-000'
      AND j.bom_id IN (SELECT s.id FROM public.portal_shared_lighthouse_bom_ids() s)
    )
  );

DROP VIEW IF EXISTS public.v_portal_job_supply CASCADE;
CREATE VIEW public.v_portal_job_supply
  WITH (security_invoker = false)
AS
SELECT
  jc.job_id,
  jc.sku_id,
  jc.item_name,
  jc.qty_required,
  jc.is_allocated,
  jc.expected_delivery
FROM public.job_components jc
WHERE public.is_client_user()
  AND COALESCE(jc.is_excluded, false) = false
  AND EXISTS (
    SELECT 1 FROM public.v_portal_jobs vj
    WHERE vj.id = jc.job_id
  );

DROP VIEW IF EXISTS public.v_portal_sku_on_site CASCADE;
CREATE VIEW public.v_portal_sku_on_site
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
  ) AS used_on_boms
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

DROP VIEW IF EXISTS public.v_portal_bom_history CASCADE;
CREATE VIEW public.v_portal_bom_history
  WITH (security_invoker = false)
AS
SELECT
  h.bom_id,
  h.action,
  h.from_status,
  h.to_status,
  h.actor,
  h.created_at,
  h.revision_number
FROM public.bom_history h
WHERE public.is_client_user()
  AND EXISTS (
    SELECT 1 FROM public.v_portal_boms vb
    WHERE vb.id = h.bom_id
  );

REVOKE ALL ON public.v_portal_boms FROM PUBLIC, anon;
REVOKE ALL ON public.v_portal_jobs FROM PUBLIC, anon;
REVOKE ALL ON public.v_portal_job_supply FROM PUBLIC, anon;
REVOKE ALL ON public.v_portal_sku_on_site FROM PUBLIC, anon;
REVOKE ALL ON public.v_portal_bom_history FROM PUBLIC, anon;

GRANT SELECT ON public.v_portal_boms TO authenticated;
GRANT SELECT ON public.v_portal_jobs TO authenticated;
GRANT SELECT ON public.v_portal_job_supply TO authenticated;
GRANT SELECT ON public.v_portal_sku_on_site TO authenticated;
GRANT SELECT ON public.v_portal_bom_history TO authenticated;

NOTIFY pgrst, 'reload schema';
