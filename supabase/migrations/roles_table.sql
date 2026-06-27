-- ============================================================
-- roles table — DB-driven role registry
--
-- Replaces the hardcoded STAFF_ROLES/ROLE_LABELS/tier arrays in
-- index.html and the FINANCE_ROLES/CREDS_ROLES in the edge
-- functions. After this migration, adding a new role is a
-- Settings UI action; no code change required.
--
-- Idempotent: safe to re-run. Seed uses ON CONFLICT DO NOTHING.
-- ============================================================

-- ── 1. Create the table ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS roles (
  key                          text PRIMARY KEY,
  label                        text NOT NULL,
  short_label                  text NOT NULL,
  sort_order                   int  NOT NULL DEFAULT 100,
  is_system                    bool NOT NULL DEFAULT false,
  -- Tier flags (replace the various PULSE_ADMIN_ROLES / EXEC_ROLES /
  -- FINANCE_ROLES / etc. arrays previously hardcoded in index.html
  -- and the supabase/functions/* edge functions).
  is_pulse_admin               bool NOT NULL DEFAULT false,
  is_exec                      bool NOT NULL DEFAULT false,
  is_hr_admin                  bool NOT NULL DEFAULT false,
  is_client_editor             bool NOT NULL DEFAULT false,
  is_broadcast_initiator       bool NOT NULL DEFAULT false,
  has_finance_access           bool NOT NULL DEFAULT false,
  has_finance_creds            bool NOT NULL DEFAULT false,
  has_stock_view               bool NOT NULL DEFAULT false,
  notify_on_client_submission  bool NOT NULL DEFAULT false,
  is_manager                   bool NOT NULL DEFAULT false,
  -- Staff-broadcast group memberships. 'all' is implicit but stored
  -- explicitly for symmetry. 'management', 'production', 'ecom' are
  -- the optional pre-canned groups in the Staff Broadcast modal.
  sb_groups                    text[] NOT NULL DEFAULT '{all}',
  -- The 25-key permission matrix (keys defined in PERMISSION_DEFS in
  -- index.html). Matrix UI reads/writes this column directly.
  permissions                  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at                   timestamptz NOT NULL DEFAULT now(),
  updated_at                   timestamptz NOT NULL DEFAULT now()
);

-- updated_at trigger
CREATE OR REPLACE FUNCTION roles_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS roles_updated_at ON roles;
CREATE TRIGGER roles_updated_at
  BEFORE UPDATE ON roles
  FOR EACH ROW EXECUTE FUNCTION roles_set_updated_at();

-- ── 2. Seed the 12 existing staff roles + 'client' pseudo-role ──
--
-- Tier memberships extracted exactly from the post-Phase-1 state
-- of index.html. Permissions blobs match DEFAULT_PERMISSIONS at
-- index.html:41983-42007 (post-Phase-1 backfill — every role has
-- every key defined). MD/OD have all flags + permissions=1.
INSERT INTO roles (key, label, short_label, sort_order, is_system,
  is_pulse_admin, is_exec, is_hr_admin, is_client_editor,
  is_broadcast_initiator, has_finance_access, has_finance_creds,
  has_stock_view, notify_on_client_submission, is_manager,
  sb_groups, permissions
) VALUES
  ('managing_director',   'Managing Director',                       'MD',           10, true,
    true,  true,  true,  true,  true,  true,  true,  true,  true,  true,
    '{all,management}',
    '{"jobs_create":1,"jobs_advance":1,"jobs_signoff_liquid":1,"jobs_signoff_quality":1,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":1,"boms_lock":1,"labels_manage":1,"production_control":1,"changeover_override":1,"bay_assign":1,"bay_release":1,"blending_write":1,"liquid_products_edit":1,"drygoods_edit":1,"clients_edit":1,"roster_view":1,"roster_edit":1,"timesheet_edit":1,"hr_view_directory":1,"hr_view_all":1,"reports_view":1,"settings_access":1,"invite_users":1}'::jsonb),
  ('operations_director', 'Operations Director',                     'Ops Dir',      20, true,
    true,  true,  true,  true,  true,  true,  true,  true,  false, true,
    '{all,management,production}',
    '{"jobs_create":1,"jobs_advance":1,"jobs_signoff_liquid":1,"jobs_signoff_quality":1,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":1,"boms_lock":1,"labels_manage":1,"production_control":1,"changeover_override":1,"bay_assign":1,"bay_release":1,"blending_write":1,"liquid_products_edit":1,"drygoods_edit":1,"clients_edit":1,"roster_view":1,"roster_edit":1,"timesheet_edit":1,"hr_view_directory":1,"hr_view_all":1,"reports_view":1,"settings_access":1,"invite_users":1}'::jsonb),
  ('business_analyst',    'Business Analyst',                        'Biz Analyst',  30, true,
    true,  false, true,  true,  false, true,  false, true,  false, true,
    '{all}',
    '{"jobs_create":1,"jobs_advance":1,"jobs_signoff_liquid":1,"jobs_signoff_quality":1,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":1,"boms_lock":0,"labels_manage":1,"production_control":1,"changeover_override":1,"bay_assign":1,"bay_release":1,"blending_write":1,"liquid_products_edit":0,"drygoods_edit":1,"clients_edit":1,"roster_view":1,"roster_edit":1,"timesheet_edit":1,"hr_view_directory":1,"hr_view_all":1,"reports_view":1,"settings_access":1,"invite_users":0}'::jsonb),
  ('financial_controller','Financial Controller',                    'Fin Ctrl',     40, true,
    false, false, false, false, false, true,  true,  true,  false, true,
    '{all,management}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":0,"boms_lock":0,"labels_manage":0,"production_control":0,"changeover_override":0,"bay_assign":0,"bay_release":0,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":0,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":1,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  ('commercial_manager',  'Commercial Manager',                      'Commercial',   50, true,
    false, false, false, true,  false, false, false, false, false, true,
    '{all}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":0,"boms_lock":0,"labels_manage":0,"production_control":0,"changeover_override":0,"bay_assign":0,"bay_release":0,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":1,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  ('ecommerce_manager',   'E-Commerce Manager',                      'E-Comm',       60, true,
    false, false, false, false, false, true,  false, false, false, true,
    '{all,ecom}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":0,"boms_lock":0,"labels_manage":0,"production_control":0,"changeover_override":0,"bay_assign":0,"bay_release":0,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":1,"clients_edit":1,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  ('production_manager',  'Production Manager',                      'Prod Mgr',     70, true,
    false, false, true,  false, false, false, false, false, false, true,
    '{all,production}',
    '{"jobs_create":1,"jobs_advance":1,"jobs_signoff_liquid":1,"jobs_signoff_quality":1,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":0,"boms_lock":0,"labels_manage":1,"production_control":1,"changeover_override":1,"bay_assign":1,"bay_release":1,"blending_write":1,"liquid_products_edit":0,"drygoods_edit":1,"clients_edit":0,"roster_view":1,"roster_edit":1,"timesheet_edit":1,"hr_view_directory":0,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  ('quality_compliance',  'Quality & Compliance Manager',            'Quality',      80, true,
    false, false, false, false, true,  false, false, false, true,  true,
    '{all,management}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":1,"jobs_signoff_quality":1,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":1,"boms_lock":1,"labels_manage":1,"production_control":0,"changeover_override":0,"bay_assign":1,"bay_release":1,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":0,"roster_view":0,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  ('warehouse_liquid',    'Warehouse & Liquid Manager',              'Warehouse',    90, true,
    false, false, false, false, false, false, false, false, false, true,
    '{all,production}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":1,"jobs_signoff_quality":0,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":0,"boms_lock":0,"labels_manage":0,"production_control":1,"changeover_override":0,"bay_assign":0,"bay_release":1,"blending_write":1,"liquid_products_edit":1,"drygoods_edit":1,"clients_edit":0,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":0,"settings_access":0,"invite_users":0}'::jsonb),
  ('client_coordinator',  'Client Coordinator',                      'Client Coord', 100, true,
    false, false, false, false, false, false, false, false, true,  false,
    '{all}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":0,"boms_lock":0,"labels_manage":1,"production_control":0,"changeover_override":0,"bay_assign":1,"bay_release":1,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":1,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":0,"settings_access":0,"invite_users":0}'::jsonb),
  ('production_operator', 'Production Operator',                     'Operator',     110, true,
    false, false, false, false, false, false, false, false, false, false,
    '{all,production}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":0,"jobs_edit_supply_chain":0,"boms_edit":0,"boms_lock":0,"labels_manage":0,"production_control":1,"changeover_override":0,"bay_assign":0,"bay_release":1,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":0,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":0,"settings_access":0,"invite_users":0}'::jsonb),
  ('order_fulfillment',   'Customer Order & Fulfillment Specialist', 'Order Fulfil.', 120, true,
    false, false, false, false, false, false, false, false, false, false,
    '{all,ecom}',
    '{"jobs_create":0,"jobs_advance":0,"jobs_signoff_liquid":0,"jobs_signoff_quality":0,"jobs_signoff_components":1,"jobs_edit_supply_chain":1,"boms_edit":0,"boms_lock":0,"labels_manage":1,"production_control":0,"changeover_override":0,"bay_assign":0,"bay_release":0,"blending_write":0,"liquid_products_edit":0,"drygoods_edit":0,"clients_edit":1,"roster_view":1,"roster_edit":0,"timesheet_edit":0,"hr_view_directory":0,"hr_view_all":0,"reports_view":1,"settings_access":0,"invite_users":0}'::jsonb),
  -- 'client' is the portal-account pseudo-role. Kept here so that the
  -- app_users.role FK applies uniformly. All flags false; permissions
  -- empty (clients hit the portal code path, not the staff dashboard).
  ('client',              'Client',                                  'Client',       999, true,
    false, false, false, false, false, false, false, false, false, false,
    '{}',
    '{}'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ── 3. Migrate any saved permission overrides ──────────────
-- The legacy app_settings.permissions row holds an admin-edited copy
-- of DEFAULT_PERMISSIONS. Override roles.permissions row-by-row, then
-- delete the settings row so the matrix UI has a single source.
--
-- The front-end persisted the matrix as JSON.stringify(...) inside
-- the (jsonb) value column, so the row may hold a JSON *string* scalar
-- like "{\"role\":{...}}" rather than a JSON *object*. We unwrap once
-- if needed before iterating its keys.
DO $$
DECLARE
  raw_val jsonb;
  saved   jsonb;
  rolekey text;
BEGIN
  SELECT value::jsonb INTO raw_val
    FROM app_settings
   WHERE key = 'permissions'
   LIMIT 1;
  IF raw_val IS NULL THEN
    RETURN;
  END IF;
  IF jsonb_typeof(raw_val) = 'string' THEN
    saved := (raw_val #>> '{}')::jsonb;  -- unwrap one layer of stringification
  ELSE
    saved := raw_val;
  END IF;
  IF jsonb_typeof(saved) = 'object' THEN
    FOR rolekey IN SELECT jsonb_object_keys(saved) LOOP
      UPDATE roles
         SET permissions = roles.permissions || (saved -> rolekey)
       WHERE key = rolekey;
    END LOOP;
  END IF;
  DELETE FROM app_settings WHERE key = 'permissions';
END $$;

-- ── 4. Replace CHECK constraint with FK to roles(key) ──────
-- The Phase-1 CHECK constraint was useful as a guard while we
-- consolidated, but a hardcoded list is exactly the rigidity we
-- are now retiring. Replace with FK so the DB enforces only that
-- app_users.role refers to a row that actually exists.
ALTER TABLE app_users
  DROP CONSTRAINT IF EXISTS app_users_role_check;

-- Drop any prior FK from a re-run, then re-add with the desired
-- ON UPDATE/DELETE behaviour.
ALTER TABLE app_users
  DROP CONSTRAINT IF EXISTS app_users_role_fkey;
ALTER TABLE app_users
  ADD CONSTRAINT app_users_role_fkey FOREIGN KEY (role)
  REFERENCES roles(key) ON UPDATE CASCADE ON DELETE RESTRICT;

-- ── 5. RLS ──────────────────────────────────────────────────
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;

-- The role registry is not sensitive (just labels and permission
-- flags) and the front end needs it both pre-auth (invite/register
-- screens render role labels) and post-auth. Allow SELECT to anon
-- and authenticated. Writes are blocked at the policy level — they
-- go through the service-role roles-admin edge function instead.
DROP POLICY IF EXISTS "roles_select_anon"          ON roles;
DROP POLICY IF EXISTS "roles_select_authenticated" ON roles;
CREATE POLICY "roles_select_anon"          ON roles
  FOR SELECT TO anon USING (true);
CREATE POLICY "roles_select_authenticated" ON roles
  FOR SELECT TO authenticated USING (true);

GRANT SELECT ON roles TO anon, authenticated;
