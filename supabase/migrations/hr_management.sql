-- ============================================================
-- HR Management file — confidential notes + medical / private docs
--
-- Visible only to roles.is_hr_admin (MD, OD, BA, Human Resources).
-- There is NO own-row policy: the employee cannot SELECT their own
-- notes or files even if they guess the table name.
--
-- Storage bucket is PRIVATE (unlike other Pulse buckets). Downloads
-- go through short-lived signed URLs, never /object/public/.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.hr_management_notes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  body        text NOT NULL,
  created_by  uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hr_management_notes_body_check CHECK (char_length(trim(body)) > 0)
);

CREATE INDEX IF NOT EXISTS hr_management_notes_user_id_idx
  ON public.hr_management_notes (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.hr_management_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  category      text NOT NULL,
  title         text,
  file_name     text NOT NULL,
  storage_path  text NOT NULL,
  content_type  text,
  file_size     integer,
  created_by    uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hr_management_documents_category_check CHECK (category IN ('medical', 'private')),
  CONSTRAINT hr_management_documents_path_key UNIQUE (storage_path)
);

CREATE INDEX IF NOT EXISTS hr_management_documents_user_id_idx
  ON public.hr_management_documents (user_id, category, created_at DESC);

ALTER TABLE public.hr_management_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hr_management_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hr_management_notes_admin_all ON public.hr_management_notes;
CREATE POLICY hr_management_notes_admin_all ON public.hr_management_notes
  FOR ALL TO authenticated
  USING      (public.is_hr_admin())
  WITH CHECK (public.is_hr_admin());

DROP POLICY IF EXISTS hr_management_documents_admin_all ON public.hr_management_documents;
CREATE POLICY hr_management_documents_admin_all ON public.hr_management_documents
  FOR ALL TO authenticated
  USING      (public.is_hr_admin())
  WITH CHECK (public.is_hr_admin());

REVOKE ALL ON public.hr_management_notes FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_management_notes TO authenticated;

REVOKE ALL ON public.hr_management_documents FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_management_documents TO authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'hr-management-docs',
  'hr-management-docs',
  false,
  12582912,
  ARRAY['application/pdf', 'image/jpeg', 'image/png']
)
ON CONFLICT (id) DO UPDATE SET
  public             = false,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS hr_mgmt_docs_select ON storage.objects;
DROP POLICY IF EXISTS hr_mgmt_docs_insert ON storage.objects;
DROP POLICY IF EXISTS hr_mgmt_docs_update ON storage.objects;
DROP POLICY IF EXISTS hr_mgmt_docs_delete ON storage.objects;

CREATE POLICY hr_mgmt_docs_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'hr-management-docs' AND public.is_hr_admin());

CREATE POLICY hr_mgmt_docs_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'hr-management-docs' AND public.is_hr_admin());

CREATE POLICY hr_mgmt_docs_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'hr-management-docs' AND public.is_hr_admin());
