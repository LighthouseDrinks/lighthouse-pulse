-- Add the "String / Twine" dry goods category.
-- The BOM builder already has a String / Twine component (bm-string-sel /
-- string_twine_sku_id) that filters SKUs by the category name "string / twine",
-- but no matching category row existed — so nothing could ever be filed under it
-- in the Dry Goods view and the BOM dropdown was always empty.
-- Name must match the BOM_CAT_MAP key (lowercased): "string / twine".

INSERT INTO dry_goods_categories (name, sort_order)
SELECT 'String / Twine', 75
WHERE NOT EXISTS (SELECT 1 FROM dry_goods_categories WHERE lower(name) = 'string / twine');
