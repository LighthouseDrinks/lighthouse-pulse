-- Speed Supply Chain date-history lookups: one job's append-only date audit.
CREATE INDEX IF NOT EXISTS audit_log_supply_chain_date_idx
  ON public.audit_log (record_id, created_at DESC)
  WHERE action = 'supply_chain_date';
