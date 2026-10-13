-- Hibernia Distillers opening balance at CBW, from the 8 Oct 2026 finished-stock sheet.
-- Free Stock on that sheet is warehouse cases.bottles (114.04 = 114 cases and 4 loose bottles).
-- Idempotent: products are matched by name, and a lot is skipped when this note already exists.
-- Does not touch Hyde #5. Skips the empty-box pallet and the 200L GND cask.
-- Case price is stored on the SKU only. Hibernia lots keep a null unit cost.

do $import$
declare
  bal_note text := 'Opening balance from Hibernia finished stock sheet, 8 Oct 2026';
  stamp timestamptz := timestamptz '2026-10-08 12:00:00+01';
  sheet record;
  pid text;
  new_id text;
  max_num int;
  lot_id uuid;
begin
  drop table if exists hibernia_sheet;
  create temporary table hibernia_sheet (
    target_name text not null,
    bottles_per_case integer not null,
    quantity_bottles integer not null,
    case_price numeric not null,
    sku_notes text,
    is_new boolean not null
  );

  insert into hibernia_sheet (target_name, bottles_per_case, quantity_bottles, case_price, sku_notes, is_new) values
    ('Hyde #3 70cl', 6, 1032, 47.94, null, false),
    ('Hyde #4 70cl', 6, 1134, 77.94, null, false),
    ('Hyde #6 70cl', 6, 220, 65.94, null, false),
    ('Hyde #7 70cl', 6, 760, 77.94, null, false),
    ('Hyde #8 70cl', 6, 116, 53.94, null, false),
    ('Hyde #9 70cl', 6, 1086, 77.94, null, false),
    ('Hyde #10 70cl', 6, 1210, 77.94, null, false),
    ('Hyde #11 70cl', 6, 1142, 83.94, null, false),
    ('Hyde #12 70cl', 6, 288, 83.94, null, false),
    ('Hyde Bandon Blend 100cl', 6, 36, 59.94, null, false),
    ('Hyde Bandon Blend 70cl', 6, 36, 47.94, null, false),
    ('Hyde Single Malt 70cl', 6, 330, 53.94, null, false),
    ('Eiregold Single Malt 70cl', 6, 138, 41.94, null, false),
    ('Eiregold Blended 70cl', 6, 228, 29.94, null, false),
    ('Finity Irish Honey 70cl', 6, 1380, 29.94, null, false),
    ('Forge 70cl', 6, 688, 29.94, '70cl · 40% ABV', true),
    ('Hyde Triple Oak Bourbon Cask 70cl', 6, 42, 35.94, '70cl · 40% ABV', true),
    ('Hyde 10YO Sherry Blend 70cl', 6, 1194, 99.00, '70cl · 43% ABV', true),
    ('Hyde 10YO Triple Cask 70cl', 6, 66, 99.00, '70cl · 46% ABV', true),
    ('Hyde 25YO Single Malt 70cl', 8, 327, 1080.00, '70cl · 46% ABV', true),
    ('Hyde Cask Strength Bourbon 70cl', 6, 2334, 59.94, '70cl · 59% ABV', true),
    ('Hyde Cask Strength Oloroso 70cl', 6, 1782, 71.94, '70cl · 59% ABV', true),
    ('Hyde Year of the Goat 70cl', 6, 54, 65.94, '70cl · 40% ABV', true),
    ('Hyde Year of the Horse 70cl', 6, 48, 65.94, '70cl · 46% ABV', true),
    ('Hyde #7 Year of the Snake', 6, 144, 65.94, '70cl · 46% ABV', true),
    ('Hyde Bandon Blend 5cl', 24, 2856, 48.00, '5cl · 40% ABV', true),
    ('Hyde #3 5cl', 24, 5448, 48.00, '5cl · 46% ABV', true),
    ('Hyde #4 5cl', 24, 5112, 48.00, '5cl · 46% ABV', true),
    ('Hyde #6 5cl', 24, 6096, 48.00, '5cl · 46% ABV', true),
    ('Hyde #8 5cl', 24, 3912, 48.00, '5cl · 43% ABV', true),
    ('Hyde Single Malt 5cl', 24, 1992, 48.00, '5cl · 40% ABV', true),
    ('Hyde Cask Strength Single Grain 5cl', 70, 140, 48.00, '5cl · 59% ABV', true),
    ('Hernacia de Plata Tequila 70cl', 6, 240, 72.00, '70cl · 40% ABV', true);

  update public.finished_stock_products p
     set default_unit_cost = hs.case_price
    from hibernia_sheet hs
   where not hs.is_new
     and p.is_active
     and lower(p.name) = lower(hs.target_name)
     and coalesce(p.default_unit_cost, 0) = 0;

  for sheet in select * from hibernia_sheet where is_new order by target_name loop
    if exists (
      select 1 from public.finished_stock_products p
       where p.is_active and lower(p.name) = lower(sheet.target_name)
    ) then
      continue;
    end if;
    select coalesce(max((regexp_match(id, '^FS-(\d+)$'))[1]::int), 0)
      into max_num
      from public.finished_stock_products
     where id ~ '^FS-[0-9]+$';
    new_id := 'FS-' || lpad((max_num + 1)::text, 3, '0');
    insert into public.finished_stock_products (
      id, name, sku, bottles_per_case, default_unit_cost, notes, is_active, created_by, created_at
    ) values (
      new_id, sheet.target_name, new_id, sheet.bottles_per_case, sheet.case_price, sheet.sku_notes, true, bal_note, stamp
    );
  end loop;

  for sheet in select * from hibernia_sheet order by target_name loop
    select p.id into pid
      from public.finished_stock_products p
     where p.is_active and lower(p.name) = lower(sheet.target_name)
     limit 1;
    if pid is null then
      raise exception 'Finished stock SKU missing: %', sheet.target_name;
    end if;
    if exists (
      select 1 from public.finished_stock_movements m
       where m.product_id = pid and m.notes = bal_note
    ) then
      continue;
    end if;
    insert into public.finished_stock_lots (
      product_id, location, quantity_bottles, unit_cost, notes, updated_by, owner, created_at, updated_at
    ) values (
      pid, 'CBW', sheet.quantity_bottles, null, bal_note, bal_note, 'hibernia', stamp, stamp
    ) returning id into lot_id;
    insert into public.finished_stock_movements (
      product_id, lot_id, movement_type, quantity_bottles, location, unit_cost, notes, performed_by, owner, created_at
    ) values (
      pid, lot_id, 'goods_in', sheet.quantity_bottles, 'CBW', null, bal_note, bal_note, 'hibernia', stamp
    );
  end loop;

  if (select count(*) from public.finished_stock_movements where notes = bal_note) <> 33 then
    raise exception 'Expected 33 Hibernia opening movements';
  end if;

  if not exists (
    select 1
      from public.finished_stock_products p
      join public.finished_stock_lots l on l.product_id = p.id
     where p.name = 'Hyde #5 70cl'
       and l.owner = 'lighthouse'
       and l.location = 'WAREHOUSE 9'
       and l.quantity_bottles = 720
  ) then
    raise exception 'Hyde #5 lighthouse stock at Warehouse 9 is no longer 720 bottles';
  end if;

  drop table if exists hibernia_sheet;
end
$import$;
