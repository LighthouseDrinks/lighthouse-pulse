-- A saved training session must not change. The create function was security
-- invoker and authenticated could insert, so a later insert could add
-- trainees to a locked session or write a session with no trainees.
-- The function is now the only write path.

alter function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb)
  security definer;

revoke insert on table public.qms_training_sessions from public, anon, authenticated;
revoke insert on table public.qms_training_trainees from public, anon, authenticated;

revoke all on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) from public;
revoke all on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) from anon, authenticated;
grant execute on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) to authenticated;
