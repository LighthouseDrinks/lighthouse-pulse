-- A label quote can carry several labels (front, back, neck, and one more)
-- on the same row and the same PDF. Null means a single-component price.

ALTER TABLE public.dry_goods_price_quotes
  ADD COLUMN IF NOT EXISTS lines jsonb;

ALTER TABLE public.dry_goods_price_quotes
  DROP CONSTRAINT IF EXISTS dry_goods_price_quotes_lines;

ALTER TABLE public.dry_goods_price_quotes
  ADD CONSTRAINT dry_goods_price_quotes_lines CHECK (
    lines IS NULL
    OR (
      jsonb_typeof(lines) = 'array'
      AND jsonb_array_length(lines) BETWEEN 1 AND 4
    )
  );
