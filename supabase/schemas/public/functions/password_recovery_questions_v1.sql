create or replace function public.password_recovery_questions_set_v1(
  p_session_token text, p_current_password text, p_questions jsonb
) returns boolean
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile record;
  v_entry jsonb;
  v_id text;
  v_answer text;
  v_seen text[] := array[]::text[];
  v_answers text[] := array[]::text[];
begin
  select * into v_profile from private.require_app_session_v1(p_session_token);
  if not found or v_profile.role <> 'admin' then return false; end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = v_profile.profile_id and p.is_active
      and p.password = encode(extensions.digest(convert_to(coalesce(p_current_password, ''), 'UTF8'), 'sha256'), 'hex')
  ) then return false; end if;
  if jsonb_typeof(p_questions) is distinct from 'array' then return false; end if;
  if jsonb_array_length(p_questions) <> 3 then return false; end if;
  for v_entry in select value from jsonb_array_elements(p_questions) loop
    v_id := v_entry->>'id';
    v_answer := lower(regexp_replace(btrim(coalesce(v_entry->>'answer', '')), '[[:space:]]+', ' ', 'g'));
    if v_id is null or v_id not in (
      'first_pet', 'birth_city', 'first_school', 'childhood_nickname',
      'mother_maiden_name', 'first_teacher', 'childhood_best_friend',
      'first_job', 'favorite_childhood_food', 'street_grew_up',
      'first_concert', 'childhood_hero'
    ) or v_id = any(v_seen) or v_answer = any(v_answers) or
       length(v_answer) < 2 or octet_length(v_answer) > 72 then
      return false;
    end if;
    v_seen := array_append(v_seen, v_id);
    v_answers := array_append(v_answers, v_answer);
  end loop;
  delete from private.password_recovery_questions where profile_id = v_profile.profile_id;
  for v_entry in select value from jsonb_array_elements(p_questions) loop
    v_answer := lower(regexp_replace(btrim(v_entry->>'answer'), '[[:space:]]+', ' ', 'g'));
    insert into private.password_recovery_questions (profile_id, question_id, answer_hash)
    values (v_profile.profile_id, v_entry->>'id', extensions.crypt(v_answer, extensions.gen_salt('bf', 10)));
  end loop;
  update private.password_recovery_question_challenges
  set consumed_at = now()
  where profile_id = v_profile.profile_id and consumed_at is null;
  return true;
end;
$function$;

create or replace function public.password_recovery_questions_begin_v1(p_username text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_profile public.profiles%rowtype;
  v_ids text[];
  v_id uuid;
begin
  if length(btrim(coalesce(p_username, ''))) > 128 then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('questions:' || btrim(coalesce(p_username, '')), 0));
  select * into v_profile from public.profiles
  where username = btrim(coalesce(p_username, '')) and role = 'admin' and is_active;
  if not found then return null; end if;
  if (select count(*) from private.password_recovery_questions where profile_id = v_profile.id) <> 3 then
    return null;
  end if;
  if exists (
    select 1 from private.password_recovery_question_challenges
    where profile_id = v_profile.id and created_at > now() - interval '60 seconds'
  ) or (
    select count(*) from private.password_recovery_question_challenges
    where profile_id = v_profile.id and created_at > now() - interval '1 hour'
  ) >= 5 then return null; end if;
  select array_agg(question_id) into v_ids from (
    select question_id from private.password_recovery_questions
    where profile_id = v_profile.id order by random()
  ) chosen;
  v_id := extensions.gen_random_uuid();
  insert into private.password_recovery_question_challenges
    (id, profile_id, first_question_id, second_question_id, third_question_id, expires_at)
  values (v_id, v_profile.id, v_ids[1], v_ids[2], v_ids[3], now() + interval '10 minutes');
  return jsonb_build_object(
    'challenge_id', v_id,
    'question_ids', jsonb_build_array(v_ids[1], v_ids[2], v_ids[3])
  );
end;
$function$;

create or replace function public.password_recovery_questions_verify_v1(
  p_challenge_id uuid, p_first_answer text, p_second_answer text, p_third_answer text
) returns text
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_challenge private.password_recovery_question_challenges%rowtype;
  v_first_hash text;
  v_second_hash text;
  v_third_hash text;
  v_first text;
  v_second text;
  v_third text;
  v_token text;
begin
  select * into v_challenge from private.password_recovery_question_challenges
  where id = p_challenge_id for update;
  if not found or v_challenge.consumed_at is not null or
     v_challenge.reset_token_hash is not null or v_challenge.expires_at <= now() or
     v_challenge.attempts >= 3 or v_challenge.third_question_id is null then return null; end if;
  update private.password_recovery_question_challenges
  set attempts = attempts + 1 where id = p_challenge_id;
  v_first := lower(regexp_replace(btrim(coalesce(p_first_answer, '')), '[[:space:]]+', ' ', 'g'));
  v_second := lower(regexp_replace(btrim(coalesce(p_second_answer, '')), '[[:space:]]+', ' ', 'g'));
  v_third := lower(regexp_replace(btrim(coalesce(p_third_answer, '')), '[[:space:]]+', ' ', 'g'));
  if length(v_first) < 2 or octet_length(v_first) > 72 or
     length(v_second) < 2 or octet_length(v_second) > 72 or
     length(v_third) < 2 or octet_length(v_third) > 72 then return null; end if;
  select answer_hash into v_first_hash from private.password_recovery_questions
  where profile_id = v_challenge.profile_id and question_id = v_challenge.first_question_id;
  select answer_hash into v_second_hash from private.password_recovery_questions
  where profile_id = v_challenge.profile_id and question_id = v_challenge.second_question_id;
  select answer_hash into v_third_hash from private.password_recovery_questions
  where profile_id = v_challenge.profile_id and question_id = v_challenge.third_question_id;
  if v_first_hash is null or v_second_hash is null or v_third_hash is null or
     extensions.crypt(v_first, v_first_hash) <> v_first_hash or
     extensions.crypt(v_second, v_second_hash) <> v_second_hash or
     extensions.crypt(v_third, v_third_hash) <> v_third_hash then return null; end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  update private.password_recovery_question_challenges
  set reset_token_hash = extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'),
      reset_expires_at = now() + interval '5 minutes'
  where id = p_challenge_id;
  return v_token;
end;
$function$;

create or replace function public.password_recovery_questions_complete_v1(
  p_reset_token text, p_new_password text
) returns boolean
language plpgsql security definer
set search_path to 'public', 'private', 'extensions', 'pg_temp'
as $function$
declare
  v_challenge private.password_recovery_question_challenges%rowtype;
  v_username text;
begin
  if length(coalesce(p_reset_token, '')) <> 64 or
     length(coalesce(p_new_password, '')) < 8 or length(p_new_password) > 128 or
     p_new_password !~ '[A-Z]' or p_new_password !~ '[a-z]' or
     p_new_password !~ '[0-9]' or p_new_password !~ '[!@#$%^&*(),.?":{}|<>]' then
    return false;
  end if;
  select * into v_challenge from private.password_recovery_question_challenges
  where reset_token_hash = extensions.digest(convert_to(p_reset_token, 'UTF8'), 'sha256')
    and reset_expires_at > now() and consumed_at is null
  for update;
  if not found then return false; end if;
  if exists (
    select 1 from public.profiles
    where id = v_challenge.profile_id
      and password = encode(extensions.digest(
        convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  ) then
    raise exception 'New password matches current password.';
  end if;
  update public.profiles
  set password = encode(extensions.digest(convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  where id = v_challenge.profile_id and role = 'admin' and is_active
    and password <> encode(extensions.digest(
      convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  returning username into v_username;
  if not found then return false; end if;
  perform private.reset_auth_rate_limit_v1(
    'login', extensions.digest(convert_to('login:' || btrim(v_username), 'UTF8'), 'sha256')
  );
  update private.password_recovery_question_challenges
  set consumed_at = now() where id = v_challenge.id;
  return true;
end;
$function$;

revoke all on function public.password_recovery_questions_set_v1(text, text, jsonb)
  from public, authenticated;
grant execute on function public.password_recovery_questions_set_v1(text, text, jsonb)
  to anon, service_role;
revoke all on function public.password_recovery_questions_begin_v1(text)
  from public, anon, authenticated;
revoke all on function public.password_recovery_questions_verify_v1(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.password_recovery_questions_complete_v1(text, text)
  from public, anon, authenticated;
grant execute on function public.password_recovery_questions_begin_v1(text) to service_role;
grant execute on function public.password_recovery_questions_verify_v1(uuid, text, text, text) to service_role;
grant execute on function public.password_recovery_questions_complete_v1(text, text) to service_role;
