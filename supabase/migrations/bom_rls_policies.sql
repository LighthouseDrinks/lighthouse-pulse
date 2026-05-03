-- ============================================================
-- RLS Policies for BOM tables (patch)
-- ============================================================

-- job_bom_approvals
ALTER TABLE job_bom_approvals ENABLE ROW LEVEL SECURITY;

-- Staff (authenticated): full access
CREATE POLICY "job_bom_approvals_auth_all"
  ON job_bom_approvals FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Public (anon): read by token (for magic link page), update decision columns
CREATE POLICY "job_bom_approvals_anon_select"
  ON job_bom_approvals FOR SELECT
  TO anon
  USING (true);

CREATE POLICY "job_bom_approvals_anon_update"
  ON job_bom_approvals FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (true);

-- client_bom_edit_requests
ALTER TABLE client_bom_edit_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "client_bom_edit_requests_auth_all"
  ON client_bom_edit_requests FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "client_bom_edit_requests_anon_select"
  ON client_bom_edit_requests FOR SELECT
  TO anon
  USING (true);

CREATE POLICY "client_bom_edit_requests_anon_insert"
  ON client_bom_edit_requests FOR INSERT
  TO anon
  WITH CHECK (true);
