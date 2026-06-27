-- ============================================================
-- app_settings — lock down (Phase 1, finding C-4).
--
-- app_settings stored secrets (the Resend API key lives in the 'system'
-- key; Xero client id/secret in 'xero_client_id' / 'xero_client_secret')
-- but carried `authenticated_full_access` (ALL true) plus authenticated
-- read/write policies, so any logged-in client could read AND overwrite
-- system secrets.
--
-- Treatment:
--   * staff: full access (is_staff()).
--   * authenticated non-staff: SELECT only on a small allow-list of
--     non-secret keys the portal/kiosk legitimately need. Secrets
--     ('system', 'xero_*') become staff-only.
--
-- Current keys at time of writing: credit_from_email, credit_from_name,
-- ecom_stock_value, system (contains resend_key), xero_client_id,
-- xero_client_secret. None are needed by client portal users; the portal
-- only ever attempts to read 'working_day_overrides' (absent today,
-- allow-listed for forward-compat). Adjust the allow-list if a genuinely
-- non-secret, client-needed key is added later.
--
-- Idempotent / safe to re-run.
-- ============================================================

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS authenticated_full_access        ON public.app_settings;
DROP POLICY IF EXISTS settings_write                   ON public.app_settings;
DROP POLICY IF EXISTS settings_read                    ON public.app_settings;
DROP POLICY IF EXISTS plant_display_read_app_settings  ON public.app_settings;
DROP POLICY IF EXISTS staff_all                        ON public.app_settings;
DROP POLICY IF EXISTS app_settings_safe_read           ON public.app_settings;

-- Remove blanket write grants; staff writes go through the staff_all policy.
REVOKE INSERT, UPDATE, DELETE ON public.app_settings FROM anon;

CREATE POLICY staff_all ON public.app_settings
  FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff());

-- Non-secret allow-list for authenticated non-staff (client portal).
CREATE POLICY app_settings_safe_read ON public.app_settings
  FOR SELECT TO authenticated
  USING (key IN ('working_day_overrides'));
