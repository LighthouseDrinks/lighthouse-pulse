-- Deduplicate goods_in movements in dry_goods_movements.
--
-- Root cause: every dry-goods delivery logged the goods_in movement twice --
-- once from the DB trigger trg_log_batch_creation ('Delivery received. PO: …')
-- and once from an explicit frontend insert ('Goods in …'). A batch equals a
-- single delivery, so more than one goods_in per batch is always a duplicate.
-- On-site quantities are derived from dry_goods_batches.quantity_remaining and
-- are unaffected; this only cleans the movement (history) ledger.
--
-- Idempotent: re-running leaves exactly one goods_in row per batch.

-- 1) Preserve attribution: if the surviving (earliest) goods_in row has no
--    performed_by but a duplicate does, copy it onto the survivor.
with ranked as (
  select id, batch_id,
         row_number() over (partition by batch_id order by created_at asc, id asc) as rn
  from dry_goods_movements
  where movement_type = 'goods_in' and batch_id is not null
),
keepers as (
  select id as keep_id, batch_id from ranked where rn = 1
),
donor as (
  select k.keep_id,
         (select m2.performed_by
            from dry_goods_movements m2
           where m2.batch_id = k.batch_id
             and m2.movement_type = 'goods_in'
             and m2.performed_by is not null
             and btrim(m2.performed_by) <> ''
           order by m2.created_at asc
           limit 1) as pb
  from keepers k
)
update dry_goods_movements m
   set performed_by = donor.pb
  from donor
 where m.id = donor.keep_id
   and donor.pb is not null
   and (m.performed_by is null or btrim(m.performed_by) = '');

-- 2) Delete every non-earliest goods_in row per batch.
with ranked as (
  select id,
         row_number() over (partition by batch_id order by created_at asc, id asc) as rn
  from dry_goods_movements
  where movement_type = 'goods_in' and batch_id is not null
)
delete from dry_goods_movements
 where id in (select id from ranked where rn > 1);
