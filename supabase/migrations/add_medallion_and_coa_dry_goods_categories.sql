-- Add "Medallion" and "Certificate of Authenticity" dry goods categories.
-- Both behave like other per-bottle packaging components (e.g. Tin / Wire):
-- each gets a category row plus a *_sku_id column on the BOM tables.
-- Category names must match the BOM_CAT_MAP keys (lowercased):
--   "medallion" and "certificate of authenticity".

ALTER TABLE boms ADD COLUMN IF NOT EXISTS medallion_sku_id text;
ALTER TABLE boms ADD COLUMN IF NOT EXISTS coa_sku_id text;
ALTER TABLE client_bom_submissions ADD COLUMN IF NOT EXISTS medallion_sku_id text;
ALTER TABLE client_bom_submissions ADD COLUMN IF NOT EXISTS coa_sku_id text;

INSERT INTO dry_goods_categories (name, sort_order)
SELECT 'Medallion', 110
WHERE NOT EXISTS (SELECT 1 FROM dry_goods_categories WHERE lower(name) = 'medallion');

INSERT INTO dry_goods_categories (name, sort_order)
SELECT 'Certificate of Authenticity', 120
WHERE NOT EXISTS (SELECT 1 FROM dry_goods_categories WHERE lower(name) = 'certificate of authenticity');
