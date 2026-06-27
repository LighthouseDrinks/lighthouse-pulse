-- ============================================================
-- Storage buckets — stop cross-client file listing (Phase 1, finding C-7).
--
-- These buckets are PUBLIC (object downloads work via public URL with no
-- policy) but each had ONE broad SELECT policy on storage.objects that
-- let any authenticated user LIST/enumerate every file across all
-- clients. The portal never needs to list (it stores and reuses the
-- returned public URL), so we replace the broad listing policy with a
-- staff-only one, plus a client-own-prefix listing policy for
-- bom-documents (uploaded under bom-documents/<client_id>/...).
--
-- Public object-URL reads are unaffected.
--
-- A deeper hardening (make buckets private + serve via signed URLs) is a
-- Phase 2 item for genuinely sensitive content.
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── bom-documents ───────────────────────────────────────────
DROP POLICY IF EXISTS bomdoc_authenticated_select ON storage.objects;
DROP POLICY IF EXISTS bomdoc_staff_select         ON storage.objects;
DROP POLICY IF EXISTS bomdoc_client_own_select    ON storage.objects;
CREATE POLICY bomdoc_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'bom-documents' AND public.is_staff());
CREATE POLICY bomdoc_client_own_select ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'bom-documents'
    AND public.is_client_user()
    AND (storage.foldername(name))[1] = public.current_app_user_client_id()
  );

-- ── bom-gi-docs ─────────────────────────────────────────────
DROP POLICY IF EXISTS "Public read lixfzt_0" ON storage.objects;
DROP POLICY IF EXISTS bomgi_staff_select      ON storage.objects;
CREATE POLICY bomgi_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'bom-gi-docs' AND public.is_staff());

-- ── dry-goods-dockets ───────────────────────────────────────
DROP POLICY IF EXISTS dgd_authenticated_select ON storage.objects;
DROP POLICY IF EXISTS dgd_staff_select          ON storage.objects;
CREATE POLICY dgd_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'dry-goods-dockets' AND public.is_staff());

-- ── dry-goods-photos ────────────────────────────────────────
DROP POLICY IF EXISTS "Authenticated users can read dry goods photos" ON storage.objects;
DROP POLICY IF EXISTS dgphoto_staff_select ON storage.objects;
CREATE POLICY dgphoto_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'dry-goods-photos' AND public.is_staff());

-- ── label-photos ────────────────────────────────────────────
DROP POLICY IF EXISTS label_photos_public_read ON storage.objects;
DROP POLICY IF EXISTS label_photos_staff_select ON storage.objects;
CREATE POLICY label_photos_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'label-photos' AND public.is_staff());

-- ── task-attachments ────────────────────────────────────────
DROP POLICY IF EXISTS task_attachments_public_read ON storage.objects;
DROP POLICY IF EXISTS task_attachments_staff_select ON storage.objects;
CREATE POLICY task_attachments_staff_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'task-attachments' AND public.is_staff());
