-- Add an optional description/notes field to standing agenda template items.
-- Surfaced on the live agenda via a small "i" hover tooltip; the agenda row
-- itself stays minimal (topic + time). Idempotent.
alter table public.meeting_template_items add column if not exists notes text;
