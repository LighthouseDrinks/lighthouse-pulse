-- Seed production opening hours (minutes from midnight) and allow-list for safe read.
-- Windows match the previous hardcoded PROD_WINDOWS in index.html / plant-display.html.

INSERT INTO public.app_settings (key, value)
SELECT 'production_windows',
       '{"windows":[[420,630],[645,810],[840,945],[1020,1260]]}'::jsonb
WHERE NOT EXISTS (
  SELECT 1 FROM public.app_settings WHERE key = 'production_windows'
);

DROP POLICY IF EXISTS app_settings_safe_read ON public.app_settings;

CREATE POLICY app_settings_safe_read ON public.app_settings
  FOR SELECT TO authenticated
  USING (key IN ('working_day_overrides', 'production_windows'));
