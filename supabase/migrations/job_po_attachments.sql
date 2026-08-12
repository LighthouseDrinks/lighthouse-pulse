-- ============================================================
-- Job PO document attachments
--
-- Client purchase-order files (PDF, image, anything) live in
-- Storage; metadata is a jsonb array of {name, url, path} on
-- jobs and client_job_submissions. Path layout:
--   job-po-documents/<client_id>/<job_or_draft_id>/<file>
--
-- Staff have full write access. Portal clients may SELECT /
-- INSERT / DELETE only under their own client_id prefix.
-- Public object URLs still work (bucket is public); listing is
-- locked down the same way as the other buckets.
--
-- Idempotent / safe to re-run.
-- ============================================================

ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS po_attachments jsonb;

ALTER TABLE public.client_job_submissions
  ADD COLUMN IF NOT EXISTS po_attachments jsonb;

INSERT INTO storage.buckets (id, name, public)
VALUES ('job-po-documents', 'job-po-documents', true)
ON CONFLICT (id) DO NOTHING;

-- ── Staff listing + writes ──────────────────────────────────
DROP POLICY IF EXISTS jobpo_staff_select ON storage.objects;
DROP POLICY IF EXISTS jobpo_staff_insert ON storage.objects;
DROP POLICY IF EXISTS jobpo_staff_update ON storage.objects;
DROP POLICY IF EXISTS jobpo_staff_delete ON storage.objects;

CREATE POLICY jobpo_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'job-po-documents' AND public.is_staff());

CREATE POLICY jobpo_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-po-documents' AND public.is_staff());

CREATE POLICY jobpo_staff_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'job-po-documents' AND public.is_staff())
  WITH CHECK (bucket_id = 'job-po-documents' AND public.is_staff());

CREATE POLICY jobpo_staff_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'job-po-documents' AND public.is_staff());

-- ── Client own-prefix listing / insert / delete ─────────────
DROP POLICY IF EXISTS jobpo_client_own_select ON storage.objects;
DROP POLICY IF EXISTS jobpo_client_own_insert ON storage.objects;
DROP POLICY IF EXISTS jobpo_client_own_delete ON storage.objects;

CREATE POLICY jobpo_client_own_select ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'job-po-documents'
    AND public.is_client_user()
    AND (storage.foldername(name))[1] = public.current_app_user_client_id()
  );

CREATE POLICY jobpo_client_own_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'job-po-documents'
    AND public.is_client_user()
    AND (storage.foldername(name))[1] = public.current_app_user_client_id()
  );

CREATE POLICY jobpo_client_own_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'job-po-documents'
    AND public.is_client_user()
    AND (storage.foldername(name))[1] = public.current_app_user_client_id()
  );
