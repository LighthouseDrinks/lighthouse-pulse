-- Prevent duplicate vessel IDs that differ only by separators/case
-- (e.g. 'IBC078' vs 'IBC-078'), which previously created phantom register
-- entries that showed up as empty destinations.
--
-- Partial index (status <> 'archived') so an archived duplicate left behind by
-- cleanup does not collide with the live canonical vessel.
create unique index if not exists uniq_vessel_canon_active
  on vessels (regexp_replace(upper(id), '[^A-Z0-9]', '', 'g'))
  where status <> 'archived';
