-- ============================================================
-- jobs.actual_cases: widen to numeric so we can store
-- "full cases . leftover bottles" as decimals.
--
-- Example: 271 bottles with case size 6 = 45 full cases + 5
-- bottles in the last case, recorded as 45.05. An integer
-- column would silently truncate that to 45 and lose the
-- partial-case detail.
--
-- Safe to re-run: only alters the column when it is currently
-- an integer-family type. No data is lost because every
-- existing integer value casts cleanly to numeric.
-- ============================================================

DO $$
DECLARE
  v_type text;
BEGIN
  SELECT data_type
    INTO v_type
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'jobs'
     AND column_name  = 'actual_cases';

  IF v_type IN ('smallint', 'integer', 'bigint') THEN
    ALTER TABLE public.jobs
      ALTER COLUMN actual_cases TYPE numeric USING actual_cases::numeric;
  END IF;
END
$$;
