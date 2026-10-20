-- Up to four quantity options on one dry-goods price.
-- The first break is also mirrored on quantity / sell_unit_price /
-- sell_component_total / customer_total so older reads keep working.

ALTER TABLE public.dry_goods_price_quotes
  ADD COLUMN IF NOT EXISTS price_breaks jsonb;

UPDATE public.dry_goods_price_quotes
SET price_breaks = jsonb_build_array(
  jsonb_build_object(
    'quantity', quantity,
    'units_purchased', CASE
      WHEN abs((quantity * (1 + overage_pct / 100.0)) - round(quantity * (1 + overage_pct / 100.0))) < 0.000001
        THEN round(quantity * (1 + overage_pct / 100.0))
      ELSE ceil(quantity * (1 + overage_pct / 100.0))
    END,
    'material_total', round((
      (CASE
        WHEN abs((quantity * (1 + overage_pct / 100.0)) - round(quantity * (1 + overage_pct / 100.0))) < 0.000001
          THEN round(quantity * (1 + overage_pct / 100.0))
        ELSE ceil(quantity * (1 + overage_pct / 100.0))
      END)
      * (CASE price_unit
          WHEN 'per_1000' THEN supplier_unit_price / 1000.0
          WHEN 'per_case' THEN supplier_unit_price / bottles_per_case
          ELSE supplier_unit_price
        END)
    )::numeric, 2),
    'sell_unit_price', sell_unit_price,
    'component_total', sell_component_total,
    'customer_total', customer_total
  )
)
WHERE price_breaks IS NULL OR price_breaks = '[]'::jsonb;

ALTER TABLE public.dry_goods_price_quotes
  ALTER COLUMN price_breaks SET NOT NULL;

ALTER TABLE public.dry_goods_price_quotes
  DROP CONSTRAINT IF EXISTS dry_goods_price_quotes_breaks;

ALTER TABLE public.dry_goods_price_quotes
  ADD CONSTRAINT dry_goods_price_quotes_breaks CHECK (
    jsonb_typeof(price_breaks) = 'array'
    AND jsonb_array_length(price_breaks) BETWEEN 1 AND 4
  );
