-- QMS training log. A saved session is insert-only: no update or delete
-- policies, and default wide grants are revoked. Sessions and trainees are
-- written together by qms_create_training_session.
-- Idempotent. Apply once.

create table if not exists public.qms_training_sessions (
  id uuid primary key default gen_random_uuid(),
  topic text not null,
  session_date date not null,
  trainer_user_id uuid references public.app_users(id) on delete set null,
  trainer_name text not null,
  trainer_external boolean not null default false,
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  created_at timestamptz not null default now()
);

create index if not exists qms_training_sessions_date
  on public.qms_training_sessions (session_date desc, created_at desc);

create table if not exists public.qms_training_trainees (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.qms_training_sessions(id) on delete restrict,
  user_id uuid references public.app_users(id) on delete set null,
  trainee_name text not null,
  is_external boolean not null default false,
  sort_order integer not null default 0
);

create index if not exists qms_training_trainees_session
  on public.qms_training_trainees (session_id, sort_order);

alter table public.qms_training_sessions enable row level security;
alter table public.qms_training_trainees enable row level security;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'qms_training_sessions'
      and policyname = 'staff_select_qms_training_sessions'
  ) then
    create policy staff_select_qms_training_sessions on public.qms_training_sessions
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'qms_training_sessions'
      and policyname = 'staff_insert_qms_training_sessions'
  ) then
    create policy staff_insert_qms_training_sessions on public.qms_training_sessions
      for insert to authenticated with check (public.is_staff());
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'qms_training_trainees'
      and policyname = 'staff_select_qms_training_trainees'
  ) then
    create policy staff_select_qms_training_trainees on public.qms_training_trainees
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'qms_training_trainees'
      and policyname = 'staff_insert_qms_training_trainees'
  ) then
    create policy staff_insert_qms_training_trainees on public.qms_training_trainees
      for insert to authenticated with check (public.is_staff());
  end if;
end $$;

revoke all on table public.qms_training_sessions from public, anon, authenticated;
revoke all on table public.qms_training_trainees from public, anon, authenticated;
grant select, insert on table public.qms_training_sessions to authenticated;
grant select, insert on table public.qms_training_trainees to authenticated;
-- Insert is revoked in qms_training_sessions_lock_writes.sql. The create
-- function is the only write path after that migration.

create or replace function public.qms_create_training_session(
  p_topic text,
  p_session_date date,
  p_trainer_user_id uuid,
  p_trainer_name text,
  p_trainer_external boolean,
  p_trainees jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_topic text;
  v_trainer text;
  v_id uuid;
  v_actor uuid;
  v_actor_name text;
  v_actor_email text;
  v_len integer;
  v_i integer;
  v_ord integer := 0;
  v_trainee jsonb;
  v_t_name text;
  v_t_ext boolean;
  v_t_user uuid;
  v_user_text text;
begin
  if not public.is_staff() then
    raise exception 'Not allowed';
  end if;

  v_topic := btrim(coalesce(p_topic, ''));
  v_trainer := btrim(coalesce(p_trainer_name, ''));
  if v_topic = '' then
    raise exception 'Topic is required';
  end if;
  if p_session_date is null then
    raise exception 'Date is required';
  end if;
  if v_trainer = '' then
    raise exception 'Trainer is required';
  end if;
  if p_trainees is null or jsonb_typeof(p_trainees) <> 'array' or jsonb_array_length(p_trainees) = 0 then
    raise exception 'At least one trainee is required';
  end if;

  if coalesce(p_trainer_external, false) then
    p_trainer_user_id := null;
  elsif p_trainer_user_id is null then
    raise exception 'Trainer is required';
  end if;

  v_actor := public.current_app_user_id();
  select display_name, email into v_actor_name, v_actor_email
  from public.app_users
  where id = v_actor;

  insert into public.qms_training_sessions (
    topic, session_date, trainer_user_id, trainer_name, trainer_external,
    created_by_id, created_by_name, created_by_email
  ) values (
    v_topic,
    p_session_date,
    p_trainer_user_id,
    v_trainer,
    coalesce(p_trainer_external, false),
    v_actor,
    coalesce(nullif(btrim(coalesce(v_actor_name, '')), ''), v_actor_email, 'Unknown'),
    v_actor_email
  )
  returning id into v_id;

  v_len := jsonb_array_length(p_trainees);
  for v_i in 0 .. v_len - 1 loop
    v_trainee := p_trainees -> v_i;
    v_t_name := btrim(coalesce(v_trainee->>'name', ''));
    if v_t_name = '' then
      continue;
    end if;
    v_t_ext := lower(coalesce(v_trainee->>'external', '')) in ('true', 't', '1');
    v_t_user := null;
    if not v_t_ext then
      v_user_text := btrim(coalesce(v_trainee->>'user_id', ''));
      if v_user_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'Each staff trainee needs a valid person';
      end if;
      v_t_user := v_user_text::uuid;
    end if;
    insert into public.qms_training_trainees (
      session_id, user_id, trainee_name, is_external, sort_order
    ) values (
      v_id, v_t_user, v_t_name, v_t_ext, v_ord
    );
    v_ord := v_ord + 1;
  end loop;

  if v_ord = 0 then
    raise exception 'At least one trainee is required';
  end if;

  return (
    select jsonb_build_object(
      'id', s.id,
      'topic', s.topic,
      'session_date', s.session_date,
      'trainer_user_id', s.trainer_user_id,
      'trainer_name', s.trainer_name,
      'trainer_external', s.trainer_external,
      'created_by_name', s.created_by_name,
      'created_by_email', s.created_by_email,
      'created_at', s.created_at,
      'trainees', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', t.id,
            'user_id', t.user_id,
            'name', t.trainee_name,
            'external', t.is_external,
            'sort_order', t.sort_order
          )
          order by t.sort_order
        )
        from public.qms_training_trainees t
        where t.session_id = s.id
      ), '[]'::jsonb)
    )
    from public.qms_training_sessions s
    where s.id = v_id
  );
end;
$$;

revoke all on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) from public;
revoke all on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) from anon, authenticated;
grant execute on function public.qms_create_training_session(text, date, uuid, text, boolean, jsonb) to authenticated;
