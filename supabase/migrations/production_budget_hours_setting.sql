-- Weekly Day + Evening Production roster budget hours (shown on the roster to managers).

INSERT INTO public.app_settings (key, value)
SELECT 'production_budget_hours', '257'::jsonb
WHERE NOT EXISTS (
  SELECT 1 FROM public.app_settings WHERE key = 'production_budget_hours'
);
