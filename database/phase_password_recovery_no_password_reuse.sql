-- Apply after the password recovery phases to reject reuse of the current password.

CREATE OR REPLACE FUNCTION public.password_recovery_complete_v1(
  p_reset_token text, p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_temp'
AS $function$
declare
  v_challenge private.password_recovery_challenges%rowtype;
  v_username text;
begin
  if length(coalesce(p_reset_token, '')) <> 64 or
     length(coalesce(p_new_password, '')) < 8 or
     p_new_password !~ '[A-Z]' or p_new_password !~ '[a-z]' or
     p_new_password !~ '[0-9]' or
     p_new_password !~ '[!@#$%^&*(),.?":{}|<>]' then return false; end if;
  select * into v_challenge from private.password_recovery_challenges
  where reset_token_hash = extensions.digest(
    convert_to(p_reset_token, 'UTF8'), 'sha256')
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
  set password = encode(extensions.digest(
    convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  where id = v_challenge.profile_id and role = 'admin' and is_active
    and password <> encode(extensions.digest(
      convert_to(p_new_password, 'UTF8'), 'sha256'), 'hex')
  returning username into v_username;
  if not found then return false; end if;
  perform private.reset_auth_rate_limit_v1(
    'login', extensions.digest(
      convert_to('login:' || trim(v_username), 'UTF8'), 'sha256')
  );
  update private.password_recovery_challenges
  set consumed_at = now() where id = v_challenge.id;
  return true;
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
