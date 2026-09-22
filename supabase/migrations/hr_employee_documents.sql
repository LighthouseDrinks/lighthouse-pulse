-- ============================================================
-- Employee-visible documents — signed handbook + titled files
--
-- Lives on Employee Details → Documents (the employee can read these).
-- Distinct from hr_management_documents (confidential; no employee read).
--
-- Storage: existing private bucket hr-employee-docs
--   {userId}/signed-handbook/{id}.{ext}
--   {userId}/files/{id}.{ext}
--
-- RLS: HR admin write + read all. Employee SELECT own user_id only.
-- Do NOT use is_staff() for read.
--
-- Idempotent / safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.hr_employee_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES public.app_users(id) ON DELETE CASCADE,
  kind          text NOT NULL,
  title         text,
  file_name     text NOT NULL,
  storage_path  text NOT NULL,
  content_type  text,
  file_size     integer,
  created_by    uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hr_employee_documents_kind_check CHECK (kind IN ('signed_handbook', 'other')),
  CONSTRAINT hr_employee_documents_path_key UNIQUE (storage_path),
  CONSTRAINT hr_employee_documents_other_title_check
    CHECK (kind <> 'other' OR char_length(trim(coalesce(title, ''))) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS hr_employee_documents_signed_handbook_uidx
  ON public.hr_employee_documents (user_id)
  WHERE kind = 'signed_handbook';

CREATE INDEX IF NOT EXISTS hr_employee_documents_user_id_idx
  ON public.hr_employee_documents (user_id, kind, created_at DESC);

ALTER TABLE public.hr_employee_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hr_employee_documents_hr_all ON public.hr_employee_documents;
CREATE POLICY hr_employee_documents_hr_all ON public.hr_employee_documents
  FOR ALL TO authenticated
  USING      (public.is_hr_admin())
  WITH CHECK (public.is_hr_admin());

DROP POLICY IF EXISTS hr_employee_documents_own_read ON public.hr_employee_documents;
CREATE POLICY hr_employee_documents_own_read ON public.hr_employee_documents
  FOR SELECT TO authenticated
  USING (user_id = public.current_app_user_id());

REVOKE ALL ON public.hr_employee_documents FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_employee_documents TO authenticated;
