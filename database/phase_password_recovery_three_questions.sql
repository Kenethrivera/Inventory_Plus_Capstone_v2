-- Apply after phase_password_recovery_questions.sql on an existing project.
-- Expire two-question challenges before switching to three-answer verification.
begin;

alter table private.password_recovery_question_challenges
  add column if not exists third_question_id text;
update private.password_recovery_question_challenges
set consumed_at = now()
where third_question_id is null and consumed_at is null;
drop function if exists public.password_recovery_questions_verify_v1(uuid, text, text);

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
revoke all on function public.password_recovery_questions_begin_v1(text)
  from public, anon, authenticated;
grant execute on function public.password_recovery_questions_begin_v1(text) to service_role;
revoke all on function public.password_recovery_questions_verify_v1(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.password_recovery_questions_verify_v1(uuid, text, text, text)
  to service_role;

commit;
notify pgrst, 'reload schema';