-- ============================================================
-- Human Resources role — external HR advisor
--
-- Adds is_workforce_only (nav lockdown to Workforce + Org Chart)
-- and seeds the human_resources role with People permissions only.
-- Idempotent: safe to re-run.
-- ============================================================

ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS is_workforce_only boolean NOT NULL DEFAULT false;

INSERT INTO public.roles (
  key, label, short_label, sort_order, is_system,
  is_pulse_admin, is_exec, is_hr_admin, is_client_editor,
  is_broadcast_initiator, has_finance_access, has_finance_creds,
  has_stock_view, notify_on_client_submission, is_manager,
  is_workforce_only,
  sb_groups, permissions
) VALUES (
  'human_resources', 'Human Resources', 'HR', 125, true,
  false, false, true, false,
  false, false, false,
  false, false, false,
  true,
  '{all}',
  '{
    "jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,
    "jobs_signoff_components":0,"jobs_spirit_override":0,"jobs_edit_supply_chain":0,
    "boms_edit":0,"boms_lock":0,"labels_manage":0,
    "production_control":0,"changeover_override":0,"bay_assign":0,"bay_release":0,
    "blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"finished_stock_edit":0,
    "clients_edit":0,
    "roster_view":1,"roster_edit":1,"timesheet_edit":1,"hr_view_directory":1,"hr_view_all":1,
    "reports_view":0,"meetings_admin":0,"settings_access":0,"invite_users":0
  }'::jsonb
)
ON CONFLICT (key) DO UPDATE SET
  label              = EXCLUDED.label,
  short_label        = EXCLUDED.short_label,
  sort_order         = EXCLUDED.sort_order,
  is_hr_admin        = EXCLUDED.is_hr_admin,
  is_workforce_only  = EXCLUDED.is_workforce_only,
  permissions        = EXCLUDED.permissions,
  sb_groups          = EXCLUDED.sb_groups,
  updated_at         = now();
