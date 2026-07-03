-- Add the "Wire" dry goods category and its BOM component columns.
-- Wire behaves like other per-bottle packaging components (e.g. Tin):
-- it gets a category row plus a wire_sku_id column on the BOM tables.

ALTER TABLE boms ADD COLUMN IF NOT EXISTS wire_sku_id text;
ALTER TABLE client_bom_submissions ADD COLUMN IF NOT EXISTS wire_sku_id text;

INSERT INTO dry_goods_categories (name, sort_order)
SELECT 'Wire', 100
WHERE NOT EXISTS (SELECT 1 FROM dry_goods_categories WHERE lower(name) = 'wire');
