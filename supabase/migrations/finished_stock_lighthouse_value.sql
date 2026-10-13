-- Hibernia Distillers stock is not ours, so its case price is zero.
-- Hyde #5 and Hyde #12 are Lighthouse Drinks. Their recorded case price
-- belongs on the lot so finished-stock value and the overview tile include it.

update public.finished_stock_products p
   set default_unit_cost = 0
 where exists (
   select 1
     from public.finished_stock_lots l
    where l.product_id = p.id
      and l.owner = 'hibernia'
 )
   and p.id <> 'FS-015';

update public.finished_stock_lots
   set unit_cost = 0
 where owner = 'hibernia'
   and unit_cost is distinct from 0;

update public.finished_stock_lots
   set unit_cost = 31.02,
       updated_at = now()
 where product_id = 'FS-007'
   and owner = 'lighthouse';

update public.finished_stock_lots
   set owner = 'lighthouse',
       unit_cost = 83.94,
       updated_at = now()
 where product_id = 'FS-015';

update public.finished_stock_movements
   set owner = 'lighthouse',
       unit_cost = 83.94
 where product_id = 'FS-015'
   and movement_type = 'goods_in';
