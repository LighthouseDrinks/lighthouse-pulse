-- ============================================================
-- Client Portal — multi-tenant RLS lockdown (Phase 1, finding C-1/C-3/H-4).
--
-- The portal authenticates a Supabase user, resolves role + client_id
-- from app_users, and reads via PostgREST with that user's JWT. RLS is
-- therefore the ONLY real tenant boundary. Several core tables carried
-- permissive "always true" policies (plant-display reads, legacy
-- authenticated_full_access, an open BOM DELETE) that let any logged-in
-- client read/modify every brand's data. This migration removes those
-- and replaces them with client-scoped policies, keeping staff full
-- access via is_staff().
--
-- VERIFIED SAFE before writing:
--   * Kiosk account warehouse@lighthousedrinks.com is role
--     'production_operator' (staff) -> still covered by staff_all, so
--     dropping plant_display_read_* does NOT break plant-display.html.
--   * Portal reads dry_goods_movements only by its own SKU ids
--     (loadPortalDryGoods, index.html ~L4718) -> SKU-join scope is
--     sufficient.
--   * Portal reads/writes bom_history only for its own BOMs
--     (loadBomHistory L12184; revision audit row L3699).
--   * clients had NO client UPDATE policy -> savePortalProfile (L3139)
--     silently failed; this adds a column-scoped UPDATE (fixes H-3).
--
-- Idempotent / safe to re-run. is_staff() is hardened separately in
-- fix_is_staff_and_app_users_insert.sql (apply that one too).
-- ============================================================

-- ── jobs ────────────────────────────────────────────────────
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
-- Cross-tenant leak: any authenticated user could read every job.
DROP POLICY IF EXISTS plant_display_read_jobs ON public.jobs;
-- Legacy client_users-based policies (current_client_id) — portal users
-- are in app_users, not client_users, so these grant nothing useful and
-- only add confusion. The current_app_user_* policies replace them.
DROP POLICY IF EXISTS client_own_jobs   ON public.jobs;
DROP POLICY IF EXISTS client_insert_jobs ON public.jobs;
-- Keep: client_read_own (is_client_user AND client_id scope), staff_all.

-- ── clients ─────────────────────────────────────────────────
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS plant_display_read_clients ON public.clients;
DROP POLICY IF EXISTS client_see_own ON public.clients;  -- legacy current_client_id
-- Keep: client_read_own (SELECT), staff_all.
-- Add a row-scoped UPDATE so clients can edit ONLY their own record
-- (fixes H-3: savePortalProfile previously had no client UPDATE policy and
-- silently failed). Column-level restriction is enforced by the trigger
-- below rather than a GRANT, because a column GRANT would also limit
-- STAFF (both are the 'authenticated' role).
DROP POLICY IF EXISTS client_update_own ON public.clients;
CREATE POLICY client_update_own ON public.clients
  FOR UPDATE TO authenticated
  USING      (public.is_client_user() AND id = public.current_app_user_client_id())
  WITH CHECK (public.is_client_user() AND id = public.current_app_user_client_id());

-- A client may only change contact fields; every other column is reset to
-- its previous value. Staff updates (is_client_user() = false) are untouched.
CREATE OR REPLACE FUNCTION public.clients_client_update_guard()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF public.is_client_user() THEN
    NEW.id                     := OLD.id;
    NEW.name                   := OLD.name;
    NEW.owner_id               := OLD.owner_id;
    NEW.is_internal            := OLD.is_internal;
    NEW.lifecycle_stage        := OLD.lifecycle_stage;
    NEW.client_since           := OLD.client_since;
    NEW.created_at             := OLD.created_at;
    NEW.referred_by            := OLD.referred_by;
    NEW.industry               := OLD.industry;
    NEW.website                := OLD.website;
    NEW.lead_source            := OLD.lead_source;
    NEW.notes                  := OLD.notes;
    NEW.first_contacted_at     := OLD.first_contacted_at;
    NEW.became_prospect_at     := OLD.became_prospect_at;
    NEW.became_customer_at     := OLD.became_customer_at;
    NEW.became_client_at       := OLD.became_client_at;
    NEW.churned_at             := OLD.churned_at;
    NEW.xero_contact_id        := OLD.xero_contact_id;
    NEW.xero_contact_mapped_at := OLD.xero_contact_mapped_at;
    NEW.xero_contact_mapped_by := OLD.xero_contact_mapped_by;
    -- Editable by clients: country, address, contact_name, email, phone.
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_clients_client_update_guard ON public.clients;
CREATE TRIGGER trg_clients_client_update_guard
  BEFORE UPDATE ON public.clients
  FOR EACH ROW EXECUTE FUNCTION public.clients_client_update_guard();

-- ── boms ────────────────────────────────────────────────────
ALTER TABLE public.boms ENABLE ROW LEVEL SECURITY;
-- Open DELETE: any authenticated user could delete any client's BOM.
DROP POLICY IF EXISTS "Authenticated users can delete boms" ON public.boms;
DROP POLICY IF EXISTS client_own_boms    ON public.boms;  -- legacy current_client_id
DROP POLICY IF EXISTS client_insert_boms ON public.boms;  -- portal proposes via client_bom_submissions, not boms
-- Keep: client_read_own (SELECT), staff_all.

-- ── dry_goods_movements ─────────────────────────────────────
ALTER TABLE public.dry_goods_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_full_access ON public.dry_goods_movements;
DROP POLICY IF EXISTS staff_all                 ON public.dry_goods_movements;
DROP POLICY IF EXISTS client_read_own           ON public.dry_goods_movements;
CREATE POLICY staff_all ON public.dry_goods_movements
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
CREATE POLICY client_read_own ON public.dry_goods_movements
  FOR SELECT TO authenticated
  USING (
    public.is_client_user()
    AND sku_id IN (
      SELECT id FROM public.dry_goods_skus
      WHERE client_id = public.current_app_user_client_id()
    )
  );

-- ── bom_history ─────────────────────────────────────────────
ALTER TABLE public.bom_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bom_history_auth_all                       ON public.bom_history;
DROP POLICY IF EXISTS "Authenticated users can read bom_history" ON public.bom_history;
DROP POLICY IF EXISTS "Authenticated users can insert bom_history" ON public.bom_history;
DROP POLICY IF EXISTS staff_all                                  ON public.bom_history;
DROP POLICY IF EXISTS client_read_own                            ON public.bom_history;
DROP POLICY IF EXISTS client_insert_own                          ON public.bom_history;
CREATE POLICY staff_all ON public.bom_history
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
-- bom_id is TEXT matching boms.id (see bom_history_rls.sql).
CREATE POLICY client_read_own ON public.bom_history
  FOR SELECT TO authenticated
  USING (
    public.is_client_user()
    AND bom_id IN (
      SELECT id FROM public.boms
      WHERE client_id = public.current_app_user_client_id()
    )
  );
CREATE POLICY client_insert_own ON public.bom_history
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_client_user()
    AND bom_id IN (
      SELECT id FROM public.boms
      WHERE client_id = public.current_app_user_client_id()
    )
  );

-- ── hr_profiles ─────────────────────────────────────────────
-- Wide-open policy let clients read all staff HR data. Drop it; the
-- existing admin + own-row policies then govern access (staff only).
ALTER TABLE public.hr_profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_full_access ON public.hr_profiles;

-- ── client_bom_edit_requests ────────────────────────────────
ALTER TABLE public.client_bom_edit_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS client_bom_edit_requests_anon_insert ON public.client_bom_edit_requests;
DROP POLICY IF EXISTS client_bom_edit_requests_anon_select ON public.client_bom_edit_requests;
DROP POLICY IF EXISTS client_bom_edit_requests_auth_all    ON public.client_bom_edit_requests;
DROP POLICY IF EXISTS staff_all        ON public.client_bom_edit_requests;
DROP POLICY IF EXISTS client_own       ON public.client_bom_edit_requests;
REVOKE ALL ON public.client_bom_edit_requests FROM anon;
CREATE POLICY staff_all ON public.client_bom_edit_requests
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
CREATE POLICY client_own ON public.client_bom_edit_requests
  FOR ALL TO authenticated
  USING      (public.is_client_user() AND client_id = public.current_app_user_client_id())
  WITH CHECK (public.is_client_user() AND client_id = public.current_app_user_client_id());

-- ── pending_invites ─────────────────────────────────────────
-- Contains invitee emails/roles/client_ids — staff only.
ALTER TABLE public.pending_invites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_full_access ON public.pending_invites;
DROP POLICY IF EXISTS pending_invites_all       ON public.pending_invites;
DROP POLICY IF EXISTS staff_all                 ON public.pending_invites;
CREATE POLICY staff_all ON public.pending_invites
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
-- NOTE: the registration self-insert validates against this table via a
-- SECURITY DEFINER trigger (fix_is_staff_and_app_users_insert.sql), so it
-- does not need a client-facing SELECT policy.

-- ── liquid_products ─────────────────────────────────────────
-- Had public SELECT/INSERT/UPDATE/DELETE = true. liquid_products has a
-- client_id column, so the open SELECT leaked every brand's products and
-- the open writes let anyone modify the register.
ALTER TABLE public.liquid_products ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS liquid_products_select ON public.liquid_products;
DROP POLICY IF EXISTS liquid_products_insert ON public.liquid_products;
DROP POLICY IF EXISTS liquid_products_update ON public.liquid_products;
DROP POLICY IF EXISTS liquid_products_delete ON public.liquid_products;
DROP POLICY IF EXISTS staff_all              ON public.liquid_products;
DROP POLICY IF EXISTS client_read_own        ON public.liquid_products;
REVOKE INSERT, UPDATE, DELETE ON public.liquid_products FROM anon;
CREATE POLICY staff_all ON public.liquid_products
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());
-- Clients see global (client_id IS NULL) products plus their own. The
-- portal still filters client-side; this makes the boundary real.
CREATE POLICY client_read_own ON public.liquid_products
  FOR SELECT TO authenticated
  USING (
    public.is_client_user()
    AND (client_id IS NULL OR client_id = public.current_app_user_client_id())
  );
