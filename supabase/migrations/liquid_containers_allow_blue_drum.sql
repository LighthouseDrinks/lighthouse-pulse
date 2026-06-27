-- ============================================================
-- liquid_containers: allow 'blue_drum' in the type CHECK constraint.
-- Safe to re-run: idempotent. No table scan, no data changes.
--
-- Strategy: read the current constraint definition with
-- pg_get_constraintdef, splice the existing predicate back in
-- verbatim, and OR in `type = 'blue_drum'`. The resulting
-- predicate is a strict superset of the old one, so every
-- previously-accepted value still passes. NOT VALID skips the
-- existing-row recheck, guaranteeing the migration cannot fail
-- on already-stored data even in unexpected edge cases.
-- ============================================================

DO $$
DECLARE
  v_def       text;
  v_predicate text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
    INTO v_def
    FROM pg_constraint c
    JOIN pg_class     t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname = 'public'
     AND t.relname = 'liquid_containers'
     AND c.conname = 'liquid_containers_type_check';

  IF v_def IS NULL THEN
    -- No constraint with that name exists; install one that
    -- mirrors the UI dropdown. NOT VALID so any pre-existing
    -- row with a legacy type value cannot block the migration.
    ALTER TABLE public.liquid_containers
      ADD CONSTRAINT liquid_containers_type_check
      CHECK (type IN ('cask','ibc','blue_drum','tank','tanker'))
      NOT VALID;

  ELSIF position('blue_drum' IN v_def) = 0 THEN
    -- Strip the leading "CHECK (" and trailing ")" so we can
    -- reuse the existing predicate verbatim. Allow optional
    -- trailing whitespace just in case.
    v_predicate := regexp_replace(v_def, '^CHECK\s*\((.*)\)\s*$', '\1');

    ALTER TABLE public.liquid_containers
      DROP CONSTRAINT liquid_containers_type_check;

    EXECUTE format(
      'ALTER TABLE public.liquid_containers
         ADD CONSTRAINT liquid_containers_type_check
         CHECK ((%s) OR type = ''blue_drum'')
         NOT VALID',
      v_predicate
    );
  END IF;
END
$$;
