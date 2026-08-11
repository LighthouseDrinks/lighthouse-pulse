-- One-time backfill: set job_ready_date / liquid_ready_date from dry-goods ETAs
-- for live jobs that already had component dates but never opened Supply Chain
-- (which previously was the only place that ran recomputeJobReady).
WITH stock AS (
  SELECT sku_id, SUM(quantity_remaining) AS qty
  FROM dry_goods_batches
  GROUP BY sku_id
),
ready AS (
  SELECT jc.job_id,
    BOOL_OR(
      NOT COALESCE(jc.is_excluded, false)
      AND COALESCE(s.qty, 0) < COALESCE(jc.qty_required, 0)
      AND jc.expected_delivery IS NULL
    ) AS incomplete,
    MAX(CASE
      WHEN NOT COALESCE(jc.is_excluded, false)
       AND COALESCE(s.qty, 0) < COALESCE(jc.qty_required, 0)
      THEN jc.expected_delivery END) AS max_eta,
    COUNT(*) FILTER (
      WHERE NOT COALESCE(jc.is_excluded, false)
        AND COALESCE(s.qty, 0) < COALESCE(jc.qty_required, 0)
    ) AS short_n
  FROM job_components jc
  LEFT JOIN stock s ON s.sku_id = jc.sku_id
  JOIN jobs j ON j.id = jc.job_id
  LEFT JOIN boms b ON b.id = j.bom_id
  WHERE j.stage IN ('new','active')
    AND j.actual_start IS NULL AND j.changeover_start IS NULL
    AND NOT COALESCE(j.job_ready_manual, false)
    AND (b.liquid_sku_id IS NULL OR jc.sku_id IS DISTINCT FROM b.liquid_sku_id)
  GROUP BY jc.job_id
),
computed AS (
  SELECT j.id,
    CASE
      WHEN r.job_id IS NULL THEN NULL
      WHEN r.incomplete THEN NULL
      WHEN r.short_n = 0 THEN CURRENT_DATE
      ELSE r.max_eta
    END AS ready_date
  FROM jobs j
  LEFT JOIN ready r ON r.job_id = j.id
  WHERE j.stage IN ('new','active')
    AND j.actual_start IS NULL AND j.changeover_start IS NULL
    AND NOT COALESCE(j.job_ready_manual, false)
)
UPDATE jobs j
SET job_ready_date = c.ready_date,
    liquid_ready_date = c.ready_date
FROM computed c
WHERE j.id = c.id
  AND j.job_ready_date IS DISTINCT FROM c.ready_date;
