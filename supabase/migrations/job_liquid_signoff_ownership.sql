-- Capture per-vessel liquid ownership at job close on the liquid sign-off.
-- Ownership is fluid: anybody's liquid can be used in anybody's job, and the
-- owner of each resulting vessel/output is decided when the job is closed. This
-- column stores an immutable snapshot of that decision so the Job Liquid Report
-- can show a stable "owner before -> owner after" per vessel, independent of the
-- live liquid_containers.liquid_owner_client_id (which may later be changed in
-- liquid inventory, the supported correction path).
--
-- Shape: jsonb array of
--   { containerId, ref, role: 'source'|'leftover'|'bottled', ownerBefore, ownerAfter }
--
-- Additive + idempotent: safe to re-run; nullable, no default, non-locking; no
-- effect on existing rows.

ALTER TABLE public.job_liquid_signoff
  ADD COLUMN IF NOT EXISTS ownership_json jsonb;
