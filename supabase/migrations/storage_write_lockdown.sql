-- ============================================================
-- Storage write lockdown (Phase 2 of storage_listing_lockdown.sql).
--
-- storage_listing_lockdown.sql tightened SELECT (listing) but left the
-- INSERT / UPDATE / DELETE policies wide open: every bucket allowed ANY
-- authenticated user (incl. a client-portal JWT) to upload/overwrite/
-- delete objects with no tenant check, e.g.:
--     "Authenticated users can upload dry goods photos"  (INSERT)
--     task_attachments_auth_insert / _delete
--     label_photos_auth_write / _delete
--     bomdoc_authenticated_insert  (INSERT, any client, any prefix)
--     dgd_authenticated_insert
--     "Authenticated users can upload lixfzt_0" (bom-gi-docs)
--
-- Fix: writes become staff-only (is_staff()) on every bucket, EXCEPT
-- bom-documents, where the client portal legitimately uploads BOM
-- attachments under bom-documents/<client_id>/... The portal only ever
-- INSERTs new timestamped objects (never UPDATE/DELETE), so clients get
-- an own-prefix INSERT and nothing else. Staff keep full write access
-- everywhere.
--
-- SELECT policies from storage_listing_lockdown.sql are left in place
-- (staff + bom-documents client-own-prefix listing).
--
-- Idempotent / safe to re-run.
-- ============================================================

-- ── Drop the old broad write policies (names from live pg_policies) ──
DROP POLICY IF EXISTS "Authenticated users can upload dry goods photos" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can update dry goods photos" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can delete dry goods photos" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can upload lixfzt_0"          ON storage.objects;
DROP POLICY IF EXISTS bomdoc_authenticated_insert  ON storage.objects;
DROP POLICY IF EXISTS dgd_authenticated_insert       ON storage.objects;
DROP POLICY IF EXISTS label_photos_auth_write        ON storage.objects;
DROP POLICY IF EXISTS label_photos_auth_delete       ON storage.objects;
DROP POLICY IF EXISTS task_attachments_auth_insert   ON storage.objects;
DROP POLICY IF EXISTS task_attachments_auth_delete   ON storage.objects;

-- ── Staff write access on every managed bucket ──────────────
DO $mig$
DECLARE
  b text;
  buckets text[] := ARRAY[
    'bom-documents','bom-gi-docs','dry-goods-dockets',
    'dry-goods-photos','label-photos','task-attachments'
  ];
BEGIN
  FOREACH b IN ARRAY buckets LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_staff_insert');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_staff_update');
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', b || '_staff_delete');
    EXECUTE format(
      'CREATE POLICY %I ON storage.objects FOR INSERT TO authenticated '
      || 'WITH CHECK (bucket_id = %L AND public.is_staff())',
      b || '_staff_insert', b);
    EXECUTE format(
      'CREATE POLICY %I ON storage.objects FOR UPDATE TO authenticated '
      || 'USING (bucket_id = %L AND public.is_staff()) '
      || 'WITH CHECK (bucket_id = %L AND public.is_staff())',
      b || '_staff_update', b, b);
    EXECUTE format(
      'CREATE POLICY %I ON storage.objects FOR DELETE TO authenticated '
      || 'USING (bucket_id = %L AND public.is_staff())',
      b || '_staff_delete', b);
  END LOOP;
END
$mig$;

-- ── bom-documents: client own-prefix INSERT (portal BOM attachments) ──
DROP POLICY IF EXISTS bomdoc_client_own_insert ON storage.objects;
CREATE POLICY bomdoc_client_own_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'bom-documents'
    AND public.is_client_user()
    AND (storage.foldername(name))[1] = public.current_app_user_client_id()
  );
