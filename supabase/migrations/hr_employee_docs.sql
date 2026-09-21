-- ============================================================
-- Employee documents — contracts (per person) + company handbook
--
-- Private bucket (signed-URL downloads). Distinct from
-- hr-management-docs, which employees must never read.
--
--   {userId}/contract/{docId}.{ext}  — HR write; employee can read own
--   company/handbook.{ext}           — HR write; any staff can read
--
-- Handbook metadata lives in hr_company_documents (one row, kind=handbook)
-- so replacing the file once updates every Employee Details → Documents tab.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.hr_company_documents (
  kind          text PRIMARY KEY,
  storage_path  text NOT NULL,
  file_name     text NOT NULL,
  content_type  text,
  file_size     integer,
  uploaded_by   uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hr_company_documents_kind_check CHECK (kind IN ('handbook'))
);

ALTER TABLE public.hr_company_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hr_company_documents_staff_read ON public.hr_company_documents;
CREATE POLICY hr_company_documents_staff_read ON public.hr_company_documents
  FOR SELECT TO authenticated
  USING (public.is_staff());

DROP POLICY IF EXISTS hr_company_documents_hr_write ON public.hr_company_documents;
CREATE POLICY hr_company_documents_hr_write ON public.hr_company_documents
  FOR ALL TO authenticated
  USING      (public.is_hr_admin())
  WITH CHECK (public.is_hr_admin());

REVOKE ALL ON public.hr_company_documents FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_company_documents TO authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'hr-employee-docs',
  'hr-employee-docs',
  false,
  12582912,
  ARRAY['application/pdf', 'image/jpeg', 'image/png']
)
ON CONFLICT (id) DO UPDATE SET
  public             = false,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS hr_emp_docs_select ON storage.objects;
DROP POLICY IF EXISTS hr_emp_docs_insert ON storage.objects;
DROP POLICY IF EXISTS hr_emp_docs_update ON storage.objects;
DROP POLICY IF EXISTS hr_emp_docs_delete ON storage.objects;

CREATE POLICY hr_emp_docs_select ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'hr-employee-docs'
    AND (
      public.is_hr_admin()
      OR (storage.foldername(name))[1] = public.current_app_user_id()::text
      OR (
        public.is_staff()
        AND (storage.foldername(name))[1] = 'company'
      )
    )
  );

CREATE POLICY hr_emp_docs_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'hr-employee-docs' AND public.is_hr_admin());

CREATE POLICY hr_emp_docs_update ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'hr-employee-docs' AND public.is_hr_admin())
  WITH CHECK (bucket_id = 'hr-employee-docs' AND public.is_hr_admin());

CREATE POLICY hr_emp_docs_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'hr-employee-docs' AND public.is_hr_admin());
